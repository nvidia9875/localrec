#!/usr/bin/env python3
"""評価用の音声フィクスチャを生成する。

macOS の `say` で正解テキストから音声を作り、ffmpeg で劣化版も用意する。
正解が完全に分かっているので CER が厳密に出る。合成音声は実環境より
きれいすぎるが、チューニングの回帰検知には十分で、完全に自動化できる。

実環境に近い条件は eval/real/ の実会議音源で別途測る。

使い方:
    python3 eval/make_fixtures.py                # 全部生成
    python3 eval/make_fixtures.py --only clean   # 条件を絞る
    python3 eval/make_fixtures.py --limit 5      # 動作確認用に少数だけ
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CORPUS = ROOT / "corpus" / "ja_sentences.json"
FIXTURES = ROOT / "fixtures"

# ASR の入力は 16kHz モノラルに揃える。Whisper も SpeechAnalyzer もこれが前提。
SAMPLE_RATE = 16000

# 主話者。条件間で声を固定しないと、劣化の効果と声の違いが混ざる。
PRIMARY_VOICE = "Kyoko"
# 声への過適合を検知するための第2話者。このマシンで利用可能な ja_JP ボイスから選ぶ。
SECONDARY_VOICE = "Rocko"


@dataclass(frozen=True)
class Condition:
    """劣化条件。clean からの ffmpeg 変換で作る。"""

    name: str
    label: str
    filters: str | None = None
    # 声を変える条件は say からやり直す
    voice: str | None = None


# 生成された音声がこれより短ければ、say が失敗して無音を吐いたとみなす。
#
# macOS は `say -v '?'` に未ダウンロードのボイスも並べる。それを指定すると
# エラーにならず 0.016 秒の無音ファイルができる。気づかずに評価を回すと
# その条件だけ CER 100% になり、原因不明の「精度が悪い条件」として残る。
MIN_AUDIO_SECONDS = 0.3


CONDITIONS: list[Condition] = [
    Condition("clean", "クリーン（原音）"),
    # 会議室の空調やファンノイズ相当
    Condition("noise20", "ホワイトノイズ SNR 20dB", filters="anoisesrc=amplitude=0.02[n];[0][n]amix=inputs=2:duration=first"),
    Condition("noise10", "ホワイトノイズ SNR 10dB", filters="anoisesrc=amplitude=0.06[n];[0][n]amix=inputs=2:duration=first"),
    # 電話・低品質回線相当。8kHz に落として戻す
    Condition("phone", "8kHz 相当の帯域制限", filters="aresample=8000,aresample=16000,highpass=f=300,lowpass=f=3400"),
    # マイクが遠い / 声が小さい
    Condition("quiet", "音量 -20dB", filters="volume=-20dB"),
]

# 別話者の条件は既定で無効。このマシンでは Kyoko 以外の日本語ボイスが
# 実体を持たず無音になるため。System Settings → アクセシビリティ →
# 読み上げコンテンツ からボイスを追加した上で --only voice2 で有効化する。
OPTIONAL_CONDITIONS: list[Condition] = [
    Condition("voice2", f"別話者（{SECONDARY_VOICE}）", voice=SECONDARY_VOICE),
]

ALL_CONDITIONS = CONDITIONS + OPTIONAL_CONDITIONS


def check_tools() -> None:
    missing = [tool for tool in ("say", "ffmpeg") if shutil.which(tool) is None]
    if missing:
        sys.exit(f"必要なコマンドが見つかりません: {', '.join(missing)}")


def available_voices() -> set[str]:
    output = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return {line.split()[0] for line in output.splitlines() if line.strip()}


def audio_seconds(path: Path) -> float:
    output = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    ).stdout.strip()
    try:
        return float(output)
    except ValueError:
        return 0.0


def synthesize(text: str, voice: str, destination: Path) -> None:
    """say で音声を作り、16kHz モノラル WAV に変換する。"""
    aiff = destination.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(aiff), "-ar", str(SAMPLE_RATE), "-ac", "1",
         "-c:a", "pcm_s16le", str(destination), "-loglevel", "error"],
        check=True,
    )
    aiff.unlink(missing_ok=True)

    # 無音を検出したら黙って進まない。ここで止めないと
    # 「その条件だけ CER 100%」という原因の分からない結果が残る。
    seconds = audio_seconds(destination)
    if seconds < MIN_AUDIO_SECONDS:
        destination.unlink(missing_ok=True)
        raise RuntimeError(
            f"ボイス '{voice}' が無音を生成しました ({seconds:.3f} 秒)。"
            f" 未ダウンロードのボイスの可能性があります。"
            f" システム設定 → アクセシビリティ → 読み上げコンテンツ から追加してください。"
        )


def degrade(source: Path, destination: Path, filters: str) -> None:
    """clean 音源に ffmpeg フィルタをかけて劣化版を作る。"""
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(source), "-filter_complex", filters,
         "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le",
         str(destination), "-loglevel", "error"],
        check=True,
    )


def build_entry(sentence: dict, condition: Condition, force: bool) -> dict | None:
    directory = FIXTURES / condition.name
    directory.mkdir(parents=True, exist_ok=True)
    audio = directory / f"{sentence['id']}.wav"

    if force or not audio.exists():
        try:
            if condition.voice is not None:
                synthesize(sentence["text"], condition.voice, audio)
            elif condition.filters is None:
                synthesize(sentence["text"], PRIMARY_VOICE, audio)
            else:
                clean = FIXTURES / "clean" / f"{sentence['id']}.wav"
                if not clean.exists():
                    synthesize(sentence["text"], PRIMARY_VOICE, clean)
                degrade(clean, audio, condition.filters)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            print(f"  生成に失敗: {sentence['id']} / {condition.name}: {error}", file=sys.stderr)
            return None

    return {
        "id": f"{sentence['id']}@{condition.name}",
        "sentence_id": sentence["id"],
        "category": sentence["category"],
        "condition": condition.name,
        "audio": str(audio),
        "reference": sentence["text"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="*", help="生成する条件名を絞る")
    parser.add_argument("--limit", type=int, help="先頭から N 文だけ生成する")
    parser.add_argument("--force", action="store_true", help="既存ファイルも作り直す")
    args = parser.parse_args()

    check_tools()

    corpus = json.loads(CORPUS.read_text(encoding="utf-8"))
    sentences = corpus["sentences"]
    if args.limit:
        sentences = sentences[: args.limit]

    conditions = CONDITIONS
    if args.only:
        conditions = [c for c in ALL_CONDITIONS if c.name in args.only]
        unknown = set(args.only) - {c.name for c in ALL_CONDITIONS}
        if unknown:
            sys.exit(f"未知の条件: {', '.join(sorted(unknown))}")

    voices = available_voices()
    for condition in conditions:
        voice = condition.voice or PRIMARY_VOICE
        if voice not in voices:
            sys.exit(f"音声 '{voice}' が利用できません。`say -v '?'` で確認してください。")

    print(f"{len(sentences)} 文 × {len(conditions)} 条件 = {len(sentences) * len(conditions)} ファイル")

    # clean を先に作る。他の条件がこれを元にするため。
    ordered = sorted(conditions, key=lambda c: c.name != "clean")

    for condition in ordered:
        print(f"  [{condition.name}] {condition.label}")
        # say は並列に走らせても安全。ffmpeg も CPU が余る。
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda s: build_entry(s, condition, args.force), sentences))

    # マニフェストは「今回生成したもの」ではなく「ディスクにある全部」から作る。
    # --only で一部だけ回したときにマニフェストが痩せてしまうのを防ぐ。
    manifest = rebuild_manifest(corpus["sentences"])
    manifest_path = FIXTURES / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"\nマニフェスト: {manifest_path}  ({len(manifest)} 件)")
    return 0


def rebuild_manifest(sentences: list[dict]) -> list[dict]:
    """fixtures/ に実在する音声だけを列挙してマニフェストを作り直す。"""
    by_id = {s["id"]: s for s in sentences}
    manifest: list[dict] = []

    for condition in ALL_CONDITIONS:
        directory = FIXTURES / condition.name
        if not directory.is_dir():
            continue
        for audio in sorted(directory.glob("*.wav")):
            sentence = by_id.get(audio.stem)
            if sentence is None:
                continue
            manifest.append({
                "id": f"{sentence['id']}@{condition.name}",
                "sentence_id": sentence["id"],
                "category": sentence["category"],
                "condition": condition.name,
                "audio": str(audio),
                "reference": sentence["text"],
            })
    return manifest


if __name__ == "__main__":
    raise SystemExit(main())
