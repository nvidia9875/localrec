#!/usr/bin/env python3
"""ベンチ結果（JSON）を Markdown の比較表にする。

複数のエンジン／設定の結果を並べて、どこで精度が落ちているかを見る。

使い方:
    python3 eval/report.py results.json
    python3 eval/report.py apple.json apple-glossary.json mlx.json -o eval/results/2026-08-11.md
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

CONDITION_LABELS = {
    "clean": "クリーン",
    "noise20": "ノイズ 20dB",
    "noise10": "ノイズ 10dB",
    "phone": "帯域制限 8kHz",
    "quiet": "音量 -20dB",
    "voice2": "別話者",
}

CATEGORY_LABELS = {
    "daily": "日常・会議定型",
    "tech": "IT・開発用語",
    "proper": "固有名詞",
    "number": "数字・日付",
    "filler": "フィラー",
}


def aggregate(rows: list[dict]) -> dict:
    """誤り文字数の合計 ÷ 正解文字数の合計。

    文ごとの CER を平均すると、短い文の 1 文字誤りが過大に効いてしまう。
    """
    ok = [r for r in rows if not r.get("error")]
    if not ok:
        return {"cer": None, "rtf": None, "count": len(rows), "errors": 0, "length": 0}

    errors = sum(r["substitutions"] + r["insertions"] + r["deletions"] for r in ok)
    length = sum(r["reference_length"] for r in ok)
    audio = sum(r["audio_duration"] for r in ok)
    elapsed = sum(r["elapsed"] for r in ok)

    # 数字の表記ゆれを正規化しない場合の CER。
    # `cer` との差が「二千二十六年」対「2026年」のような表記の違いの量になる。
    raw_available = all("cer_raw" in r for r in ok)
    raw = (
        sum(r["cer_raw"] * r["reference_length"] for r in ok) / length
        if raw_available and length
        else None
    )

    return {
        "cer": errors / length if length else None,
        "cer_raw": raw,
        "rtf": elapsed / audio if audio else None,
        "count": len(ok),
        "errors": errors,
        "length": length,
        "substitutions": sum(r["substitutions"] for r in ok),
        "insertions": sum(r["insertions"] for r in ok),
        "deletions": sum(r["deletions"] for r in ok),
    }


def percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.2f}%"


def ratio(value: float | None) -> str:
    return "—" if value is None else f"{value:.3f}"


def group_by(rows: list[dict], key: str) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[row.get(key) or "unknown"].append(row)
    return grouped


def render(runs: dict[str, list[dict]]) -> str:
    names = list(runs.keys())
    lines: list[str] = []

    lines.append("# 文字起こし精度ベンチマーク")
    lines.append("")
    lines.append("CER = 文字誤り率（低いほど良い）。RTF = 処理時間 ÷ 音声長（低いほど速い）。")
    lines.append("CER は文ごとの平均ではなく、誤り文字数の合計 ÷ 正解文字数の合計。")
    lines.append("")

    # 全体
    lines.append("## 全体")
    lines.append("")
    lines.append("| 設定 | CER | 表記ゆれ込み CER | RTF | 置換 | 挿入 | 削除 | 件数 |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for name in names:
        stats = aggregate(runs[name])
        lines.append(
            f"| {name} | **{percent(stats['cer'])}** | {percent(stats['cer_raw'])} | "
            f"{ratio(stats['rtf'])} | "
            f"{stats.get('substitutions', 0)} | {stats.get('insertions', 0)} | "
            f"{stats.get('deletions', 0)} | {stats['count']} |")
    lines.append("")
    lines.append(
        "「表記ゆれ込み CER」は漢数字とアラビア数字の違いを誤りとして数えた場合の値。"
        "両者の差が数字の書き方の違いの量にあたる。")
    lines.append("")

    # 条件別
    lines.append("## 音響条件別 CER")
    lines.append("")
    conditions = sorted(
        {row.get("condition") or "unknown" for rows in runs.values() for row in rows},
        key=lambda c: list(CONDITION_LABELS).index(c) if c in CONDITION_LABELS else 99)
    lines.append("| 条件 | " + " | ".join(names) + " |")
    lines.append("|---" * (len(names) + 1) + "|")
    for condition in conditions:
        cells = []
        for name in names:
            subset = [r for r in runs[name] if (r.get("condition") or "unknown") == condition]
            cells.append(percent(aggregate(subset)["cer"]) if subset else "—")
        lines.append(f"| {CONDITION_LABELS.get(condition, condition)} | " + " | ".join(cells) + " |")
    lines.append("")

    # カテゴリ別（クリーン条件だけ見る。劣化と混ぜると語彙の弱点が埋もれる）
    lines.append("## カテゴリ別 CER（クリーン音源のみ）")
    lines.append("")
    categories = sorted(
        {row.get("category") or "unknown" for rows in runs.values() for row in rows},
        key=lambda c: list(CATEGORY_LABELS).index(c) if c in CATEGORY_LABELS else 99)
    lines.append("| カテゴリ | " + " | ".join(names) + " |")
    lines.append("|---" * (len(names) + 1) + "|")
    for category in categories:
        cells = []
        for name in names:
            subset = [
                r for r in runs[name]
                if (r.get("category") or "unknown") == category and r.get("condition") == "clean"
            ]
            cells.append(percent(aggregate(subset)["cer"]) if subset else "—")
        lines.append(f"| {CATEGORY_LABELS.get(category, category)} | " + " | ".join(cells) + " |")
    lines.append("")

    # 誤りの多い順に実例を出す。数字だけ見ても打ち手が決まらない。
    lines.append("## 誤りの大きい例（クリーン音源）")
    lines.append("")
    primary = runs[names[0]]
    worst = sorted(
        [r for r in primary if r.get("condition") == "clean" and not r.get("error")],
        key=lambda r: r["cer"], reverse=True)[:12]
    if worst:
        lines.append("| ID | CER | 正解 | 認識結果 |")
        lines.append("|---|---|---|---|")
        for row in worst:
            if row["cer"] == 0:
                continue
            lines.append(
                f"| {row['id']} | {percent(row['cer'])} | {row['reference']} | {row['hypothesis']} |")
    lines.append("")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", help="ベンチ結果の JSON")
    parser.add_argument("-o", "--output", help="Markdown の書き出し先")
    args = parser.parse_args()

    runs: dict[str, list[dict]] = {}
    for path_str in args.results:
        path = Path(path_str)
        runs[path.stem] = json.loads(path.read_text(encoding="utf-8"))

    markdown = render(runs)

    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(markdown, encoding="utf-8")
        print(f"書き出しました: {output}")
    else:
        print(markdown)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
