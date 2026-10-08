"""プロトコル層のテスト。

ここが壊れると、アプリ側は「サイドカーが黙って何も返さない」という
一番分かりにくい形で失敗する。境界条件を厚めに押さえる。
"""

from __future__ import annotations

import json

import pytest

from audiorec_asr.protocol import (
    ProtocolError,
    Request,
    encode_error,
    encode_event,
    encode_result,
)


def test_decodes_minimal_request() -> None:
    request = Request.decode('{"id": 1, "method": "ping"}')
    assert request.id == 1
    assert request.method == "ping"
    assert request.params == {}


def test_decodes_params() -> None:
    request = Request.decode('{"id": 2, "method": "transcribe_file", "params": {"path": "/a.wav"}}')
    assert request.params["path"] == "/a.wav"


def test_params_null_is_treated_as_empty() -> None:
    assert Request.decode('{"id": 1, "method": "ping", "params": null}').params == {}


@pytest.mark.parametrize(
    "line",
    [
        "",
        "not json",
        "[1, 2, 3]",
        '"just a string"',
        '{"method": "ping"}',
        '{"id": 1}',
        '{"id": 1, "method": "ping", "params": []}',
    ],
)
def test_rejects_malformed_lines(line: str) -> None:
    with pytest.raises(ProtocolError):
        Request.decode(line)


def test_result_round_trips() -> None:
    payload = json.loads(encode_result(7, {"text": "こんにちは"}))
    assert payload == {"id": 7, "ok": True, "result": {"text": "こんにちは"}}


def test_error_carries_kind() -> None:
    payload = json.loads(encode_error(7, "見つかりません", kind="not_found"))
    assert payload["ok"] is False
    assert payload["error"]["kind"] == "not_found"


def test_event_shape() -> None:
    payload = json.loads(encode_event(3, "progress", {"fraction": 0.5}))
    assert payload["event"] == "progress"
    assert payload["data"]["fraction"] == 0.5


def test_japanese_is_not_escaped() -> None:
    # エスケープされると 1 行が無駄に長くなり、目視デバッグもしづらい
    assert "こんにちは" in encode_result(1, {"text": "こんにちは"})


def test_encoded_messages_are_single_line() -> None:
    # NDJSON なので改行が混ざると 1 メッセージが 2 行に割れて壊れる
    line = encode_result(1, {"text": "改行\nを含む"})
    assert "\n" not in line
