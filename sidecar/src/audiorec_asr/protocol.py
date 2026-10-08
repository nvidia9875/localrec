"""アプリとサイドカーの通信プロトコル。

stdin/stdout の NDJSON（1行1メッセージ）でやり取りする。HTTP を使わない理由:

- ポートを開かないので、ポート衝突もファイアウォールの警告も起きない
- 認証を考える必要がない（親プロセスしか話しかけられない）
- 親プロセスが死ねばパイプが閉じ、サイドカーも確実に終わる

メッセージの形:

    リクエスト   {"id": 1, "method": "transcribe_file", "params": {...}}
    成功         {"id": 1, "ok": true, "result": {...}}
    失敗         {"id": 1, "ok": false, "error": {"message": "...", "kind": "..."}}
    途中経過     {"id": 1, "event": "progress", "data": {"fraction": 0.4}}
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


class ProtocolError(Exception):
    """受け取った行がプロトコルとして成立していない。"""


@dataclass(frozen=True)
class Request:
    id: int
    method: str
    params: dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def decode(line: str) -> Request:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as error:
            raise ProtocolError(f"JSON として読めません: {error}") from error

        if not isinstance(payload, dict):
            raise ProtocolError("オブジェクトではありません")

        if "id" not in payload:
            raise ProtocolError("id がありません")
        if "method" not in payload:
            raise ProtocolError("method がありません")

        # `or {}` で済ませると、空リストのような偽値が素通りしてしまう。
        # 型を明示的に見る。
        raw_params = payload.get("params")
        if raw_params is None:
            params: dict[str, Any] = {}
        elif isinstance(raw_params, dict):
            params = raw_params
        else:
            raise ProtocolError("params はオブジェクトである必要があります")

        return Request(id=int(payload["id"]), method=str(payload["method"]), params=params)


def encode_result(request_id: int, result: Any) -> str:
    return json.dumps({"id": request_id, "ok": True, "result": result}, ensure_ascii=False)


def encode_error(request_id: int, message: str, kind: str = "error") -> str:
    return json.dumps(
        {"id": request_id, "ok": False, "error": {"message": message, "kind": kind}},
        ensure_ascii=False,
    )


def encode_event(request_id: int, event: str, data: Any) -> str:
    return json.dumps(
        {"id": request_id, "event": event, "data": data}, ensure_ascii=False)
