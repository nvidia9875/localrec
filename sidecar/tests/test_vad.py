"""VAD のテスト。

Whisper の無音ハルシネーション対策の要なので、
「無音を無音と判定できるか」を中心に確かめる。
"""

from __future__ import annotations

import numpy as np
import pytest

from audiorec_asr.vad import VADConfig, Segment, detect_speech, speech_ratio

SAMPLE_RATE = 16000


def tone(duration: float, amplitude: float = 0.5, freq: float = 440.0) -> np.ndarray:
    t = np.arange(int(SAMPLE_RATE * duration)) / SAMPLE_RATE
    return (np.sin(2 * np.pi * freq * t) * amplitude).astype(np.float32)


def silence(duration: float) -> np.ndarray:
    return np.zeros(int(SAMPLE_RATE * duration), dtype=np.float32)


def test_returns_nothing_for_empty_input() -> None:
    assert detect_speech(np.array([], dtype=np.float32), SAMPLE_RATE) == []


def test_returns_nothing_for_pure_silence() -> None:
    # ここが崩れると、無音に対して Whisper が定型句をでっち上げる
    assert detect_speech(silence(3.0), SAMPLE_RATE) == []


def test_detects_a_single_utterance() -> None:
    audio = np.concatenate([silence(1.0), tone(2.0), silence(1.0)])
    segments = detect_speech(audio, SAMPLE_RATE)

    assert len(segments) == 1
    # 余白ぶんの前後の広がりを許容する
    assert segments[0].start == pytest.approx(1.0, abs=0.3)
    assert segments[0].end == pytest.approx(3.0, abs=0.3)


def test_splits_on_long_silence() -> None:
    audio = np.concatenate([tone(1.0), silence(1.5), tone(1.0)])
    assert len(detect_speech(audio, SAMPLE_RATE)) == 2


def test_keeps_short_silence_inside_one_utterance() -> None:
    # 文中の息継ぎ程度の無音では切らない
    audio = np.concatenate([tone(1.0), silence(0.2), tone(1.0)])
    assert len(detect_speech(audio, SAMPLE_RATE)) == 1


def test_ignores_blips_shorter_than_minimum() -> None:
    audio = np.concatenate([silence(1.0), tone(0.05), silence(1.0)])
    assert detect_speech(audio, SAMPLE_RATE) == []


def test_threshold_is_relative_to_peak() -> None:
    # 録音レベルが小さくても同じ結果になる必要がある。
    # 絶対しきい値だと、音量の小さい録音が丸ごと無音扱いになる。
    loud = np.concatenate([silence(0.5), tone(1.0, amplitude=0.9), silence(0.5)])
    quiet = np.concatenate([silence(0.5), tone(1.0, amplitude=0.02), silence(0.5)])

    assert len(detect_speech(loud, SAMPLE_RATE)) == len(detect_speech(quiet, SAMPLE_RATE)) == 1


def test_segments_do_not_overlap_and_are_ordered() -> None:
    audio = np.concatenate([tone(0.8), silence(1.0), tone(0.8), silence(1.0), tone(0.8)])
    segments = detect_speech(audio, SAMPLE_RATE)

    for earlier, later in zip(segments, segments[1:]):
        assert earlier.end <= later.start


def test_segments_stay_inside_the_audio() -> None:
    # 余白を足した結果、音声の外にはみ出さないこと
    audio = tone(1.0)
    duration = audio.size / SAMPLE_RATE
    for segment in detect_speech(audio, SAMPLE_RATE):
        assert segment.start >= 0
        assert segment.end <= duration


def test_speech_ratio() -> None:
    assert speech_ratio([Segment(0, 1), Segment(2, 3)], 4.0) == pytest.approx(0.5)
    assert speech_ratio([], 4.0) == 0.0
    assert speech_ratio([Segment(0, 1)], 0.0) == 0.0


def test_config_is_adjustable() -> None:
    audio = np.concatenate([tone(1.0), silence(0.6), tone(1.0)])

    lenient = detect_speech(audio, SAMPLE_RATE, VADConfig(min_silence_s=1.0))
    strict = detect_speech(audio, SAMPLE_RATE, VADConfig(min_silence_s=0.4))

    assert len(lenient) == 1
    assert len(strict) == 2
