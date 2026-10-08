"""stdin/stdout の NDJSON で文字起こしを受け付ける常駐プロセス。

親プロセス（AudioRec.app）が終了すると stdin が閉じ、ここも終了する。
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
from typing import Any, Callable

from .engine import DEFAULT_MODEL, TranscribeOptions, WhisperEngine
from .protocol import ProtocolError, Request, encode_error, encode_result


class Server:
    def __init__(self, engine: WhisperEngine | None = None, out: io.TextIOBase | None = None):
        self.engine = engine or WhisperEngine()
        # プロトコル専用の出力先を先に確保しておく。
        # mlx_whisper や依存ライブラリが stdout に何か書くと NDJSON が壊れるため、
        # 処理中は sys.stdout を stderr に差し替える（下の _quiet を参照）。
        self._out = out or sys.stdout

    # -- ディスパッチ --------------------------------------------------------

    @property
    def _handlers(self) -> dict[str, Callable[[dict[str, Any]], Any]]:
        return {
            "ping": self._ping,
            "load": self._load,
            "transcribe_file": self._transcribe_file,
            "shutdown": self._shutdown,
        }

    def handle(self, request: Request) -> str:
        handler = self._handlers.get(request.method)
        if handler is None:
            return encode_error(request.id, f"未知のメソッド: {request.method}", kind="unknown_method")

        try:
            with self._quiet():
                result = handler(request.params)
        except FileNotFoundError as error:
            return encode_error(request.id, str(error), kind="not_found")
        except Exception as error:  # サイドカーは落とさない。エラーを返して次に進む。
            return encode_error(request.id, f"{type(error).__name__}: {error}", kind="internal")

        return encode_result(request.id, result)

    # -- メソッド ------------------------------------------------------------

    def _ping(self, _: dict[str, Any]) -> dict[str, Any]:
        return {"ready": True, "model": self.engine.loaded_model}

    def _load(self, params: dict[str, Any]) -> dict[str, Any]:
        model = params.get("model") or DEFAULT_MODEL
        self.engine.load(model)
        return {"model": model}

    def _transcribe_file(self, params: dict[str, Any]) -> dict[str, Any]:
        path = params.get("path")
        if not path:
            raise ValueError("path が指定されていません")
        options = TranscribeOptions.from_params(params)
        return self.engine.transcribe_file(path, options).to_dict()

    def _shutdown(self, _: dict[str, Any]) -> dict[str, Any]:
        raise SystemExit(0)

    # -- 入出力 --------------------------------------------------------------

    @contextlib.contextmanager
    def _quiet(self):
        """処理中の stdout を stderr に逃がす。

        mlx_whisper は進捗バーを出す。それが stdout に混ざると
        1行1メッセージの前提が崩れ、親プロセス側のパースが壊れる。
        """
        original = sys.stdout
        sys.stdout = sys.stderr
        try:
            yield
        finally:
            sys.stdout = original

    def emit(self, line: str) -> None:
        self._out.write(line + "\n")
        self._out.flush()

    def serve(self, source: io.TextIOBase | None = None) -> int:
        source = source or sys.stdin
        for line in source:
            line = line.strip()
            if not line:
                continue
            try:
                request = Request.decode(line)
            except ProtocolError as error:
                self.emit(encode_error(0, str(error), kind="protocol"))
                continue

            try:
                self.emit(self.handle(request))
            except SystemExit:
                self.emit(encode_result(request.id, {"stopped": True}))
                return 0
        return 0


def main() -> int:
    # 親から見た出力が遅れないよう、行バッファにする。
    sys.stdout.reconfigure(line_buffering=True)
    # Hugging Face の進捗表示も stdout を汚しうるので黙らせる。
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    return Server().serve()
