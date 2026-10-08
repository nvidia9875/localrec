#!/usr/bin/env python3
"""mlx-whisper サイドカーでマニフェストを流し、仮説テキストを書き出す。

CER の計算はここでは行わない。Swift 側（`AudioRec --score`）に一本化する。
同じ正規化を 2 つの言語で実装すると必ず食い違い、エンジン間の比較が
信用できなくなるため。

使い方:
    python3 eval/run_bench.py --model mlx-community/whisper-large-v3-mlx
    python3 eval/run_bench.py --model mlx-community/whisper-large-v3-turbo --vad
    python3 eval/run_bench.py --limit 20 --label smoke
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
MANIFEST = ROOT / "fixtures" / "manifest.json"
HYPOTHESES = ROOT / "results" / "hypotheses"
SIDECAR_PYTHON = REPO / "sidecar" / ".venv" / "bin" / "python"
SIDECAR_SRC = REPO / "sidecar" / "src"


def audio_seconds(path: Path) -> float:
    try:
        with wave.open(str(path)) as handle:
            return handle.getnframes() / handle.getframerate()
    except (wave.Error, OSError):
        return 0.0


class Sidecar:
    """サイドカーを 1 プロセス立ち上げて使い回す。

    ファイルごとにプロセスを起こすとモデルの読み込みが毎回走り、
    400 件のベンチが現実的な時間で終わらない。
    """

    def __init__(self, model: str) -> None:
        # 環境は親から引き継ぐ。PATH を絞ると Homebrew の ffmpeg が見つからず、
        # HOME を落とすと Hugging Face のモデルキャッシュを見失う。
        env = {**os.environ, "PYTHONPATH": str(SIDECAR_SRC)}
        self.process = subprocess.Popen(
            [str(SIDECAR_PYTHON), "-m", "audiorec_asr"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            cwd=str(REPO),
            env=env,
        )
        self._next_id = 0
        self.model = model

    def call(self, method: str, params: dict | None = None) -> dict:
        self._next_id += 1
        request = {"id": self._next_id, "method": method, "params": params or {}}
        assert self.process.stdin and self.process.stdout

        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

        # イベント行（途中経過）は読み飛ばし、対応する応答だけを待つ
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("サイドカーが応答せずに終了しました")
            payload = json.loads(line)
            if payload.get("id") != request["id"] or "event" in payload:
                continue
            return payload

    def close(self) -> None:
        try:
            self.call("shutdown")
        except Exception:
            pass
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="mlx-community/whisper-large-v3-mlx")
    parser.add_argument("--vad", action="store_true", help="VAD で無音を落としてから投入する")
    parser.add_argument("--prompt", help="initial_prompt に渡す文字列（用語辞書）")
    parser.add_argument("--limit", type=int, help="先頭 N 件だけ処理する")
    parser.add_argument("--label", help="出力ファイル名（既定はモデル名から作る）")
    args = parser.parse_args()

    if not SIDECAR_PYTHON.exists():
        sys.exit(f"サイドカーの Python がありません: {SIDECAR_PYTHON}")
    if not MANIFEST.exists():
        sys.exit(f"マニフェストがありません。先に make fixtures を実行してください: {MANIFEST}")

    entries = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if args.limit:
        entries = entries[: args.limit]

    label = args.label or args.model.split("/")[-1] + ("-vad" if args.vad else "")
    HYPOTHESES.mkdir(parents=True, exist_ok=True)
    destination = HYPOTHESES / f"{label}.json"

    print(f"モデル: {args.model}")
    print(f"件数: {len(entries)}  VAD: {'有効' if args.vad else '無効'}")

    sidecar = Sidecar(args.model)
    results: list[dict] = []
    try:
        print("モデルを読み込んでいます…")
        loaded = sidecar.call("load", {"model": args.model})
        if not loaded.get("ok"):
            sys.exit(f"モデルを読み込めません: {loaded['error']['message']}")

        started = time.monotonic()
        for index, entry in enumerate(entries, start=1):
            params = {
                "path": entry["audio"],
                "model": args.model,
                "language": "ja",
                "vad": args.vad,
            }
            if args.prompt:
                params["initial_prompt"] = args.prompt

            response = sidecar.call("transcribe_file", params)
            duration = audio_seconds(Path(entry["audio"]))

            if response.get("ok"):
                payload = response["result"]
                results.append({
                    "id": entry["id"],
                    "sentence_id": entry["sentence_id"],
                    "category": entry["category"],
                    "condition": entry["condition"],
                    "engine": "mlx",
                    "reference": entry["reference"],
                    "hypothesis": payload["text"],
                    "segments": len(payload["segments"]),
                    "audio_duration": payload.get("audio_duration") or duration,
                    "elapsed": payload["elapsed"],
                    "error": None,
                })
            else:
                results.append({
                    "id": entry["id"],
                    "sentence_id": entry["sentence_id"],
                    "category": entry["category"],
                    "condition": entry["condition"],
                    "engine": "mlx",
                    "reference": entry["reference"],
                    "hypothesis": "",
                    "segments": 0,
                    "audio_duration": duration,
                    "elapsed": 0.0,
                    "error": response["error"]["message"],
                })

            if index % 20 == 0 or index == len(entries):
                rate = index / max(time.monotonic() - started, 0.001)
                print(f"  {index}/{len(entries)}  ({rate:.1f} 件/秒)")
    finally:
        sidecar.close()

    destination.write_text(
        json.dumps(results, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    failures = sum(1 for r in results if r["error"])
    print(f"\n仮説: {destination}")
    if failures:
        print(f"失敗: {failures} 件")
    print(f"\n採点するには:\n  ./dist/AudioRec.app/Contents/MacOS/AudioRec"
          f" --score {destination} --out eval/results/{label}.json"
          f" -ApplePersistenceIgnoreState YES")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
