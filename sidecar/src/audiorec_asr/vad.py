"""発話区間の検出（VAD）。

なぜ要るか: Whisper は無音や環境音だけの区間に対して、学習データに
含まれていた定型句（「ご視聴ありがとうございました」など）を
でっち上げることがある。無音を先に落としておくとこれが根本から消える。

ここでは短時間エネルギーによる素朴な実装にしている。追加の依存が
不要で、テストしやすく、合成音声・会議音声のような明瞭な音源では
十分に効くため。より難しい音源が問題になったら silero-vad
(onnxruntime) への差し替えを検討する。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Segment:
    """発話区間（秒）。"""

    start: float
    end: float

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass(frozen=True)
class VADConfig:
    """しきい値の既定値は、会議音声とTTS音声の両方で無音を落とせる値にしてある。"""

    frame_ms: float = 30.0
    # 音源全体の最大エネルギーに対する比。絶対値だと録音レベルに左右される。
    relative_threshold: float = 0.02
    # 無音がこの長さ続いたら区間を切る。短すぎると文の途中で切れる。
    min_silence_s: float = 0.5
    # これより短い発話は雑音とみなす
    min_speech_s: float = 0.3
    # 区間の前後に少し余白を足す。子音の立ち上がりが切れるのを防ぐ。
    padding_s: float = 0.2


def detect_speech(
    samples: np.ndarray, sample_rate: int, config: VADConfig = VADConfig()
) -> list[Segment]:
    """発話区間を返す。音声全体が無音なら空リスト。"""
    if samples.size == 0:
        return []

    frame_length = max(1, int(sample_rate * config.frame_ms / 1000))
    frame_count = samples.size // frame_length
    if frame_count == 0:
        return []

    frames = samples[: frame_count * frame_length].reshape(frame_count, frame_length)
    energy = np.sqrt(np.mean(np.square(frames.astype(np.float64)), axis=1))

    peak = float(energy.max())
    if peak <= 0:
        return []

    is_speech = energy >= peak * config.relative_threshold
    frame_duration = frame_length / sample_rate
    total_duration = samples.size / sample_rate

    return _merge_frames(is_speech, frame_duration, total_duration, config)


def _merge_frames(
    is_speech: np.ndarray, frame_duration: float, total_duration: float, config: VADConfig
) -> list[Segment]:
    """発話フレームの並びを、区間のリストにまとめる。"""
    segments: list[Segment] = []
    start: float | None = None
    silence_run = 0.0

    for index, speaking in enumerate(is_speech):
        time = index * frame_duration
        if speaking:
            if start is None:
                start = time
            silence_run = 0.0
            continue

        if start is None:
            continue

        silence_run += frame_duration
        if silence_run >= config.min_silence_s:
            segments.append(Segment(start, time - silence_run + frame_duration))
            start = None
            silence_run = 0.0

    if start is not None:
        segments.append(Segment(start, total_duration))

    padded = [
        Segment(
            max(0.0, s.start - config.padding_s),
            min(total_duration, s.end + config.padding_s),
        )
        for s in segments
        if s.duration >= config.min_speech_s
    ]
    return _merge_overlapping(padded)


def _merge_overlapping(segments: list[Segment]) -> list[Segment]:
    """余白を足した結果として重なった区間をつなぐ。"""
    if not segments:
        return []

    merged = [segments[0]]
    for segment in segments[1:]:
        last = merged[-1]
        if segment.start <= last.end:
            merged[-1] = Segment(last.start, max(last.end, segment.end))
        else:
            merged.append(segment)
    return merged


def speech_ratio(segments: list[Segment], total_duration: float) -> float:
    """全体に占める発話区間の割合。無音がどれだけあったかの目安。"""
    if total_duration <= 0:
        return 0.0
    return sum(s.duration for s in segments) / total_duration
