"""mlx-whisper による文字起こし。

ハルシネーション対策のパラメータは、既に実運用で使われている
`/Users/shun/Desktop/props/meeting/transcribe.sh` の設定を踏襲している。
むやみに変えず、変える場合は eval のベンチで数値を確認する。
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from . import vad

# 既定のモデル。eval/ のベンチ（80文 × 5条件）で決めた。
# large-v3 より turbo の方が CER も RTF も良い（3.83% / 0.051 対 3.88% / 0.104）。
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

SAMPLE_RATE = 16000


@dataclass(frozen=True)
class TranscribeOptions:
    """文字起こしの設定。

    既定値の意図:
    - `condition_on_previous_text=False`: 直前の出力を文脈に入れると、
      一度おかしな出力が出たときに延々と引きずって「うんうん」のような
      繰り返しに陥る。会議のように話題が飛ぶ音源では切った方が安定する。
    - `no_speech_threshold=0.6`: 無音判定を厳しめにしてでっち上げを減らす。
    - `compression_ratio_threshold=2.4`: 同じ語の繰り返しを検出して打ち切る。
    """

    model: str = DEFAULT_MODEL
    language: str = "ja"
    initial_prompt: str | None = None
    condition_on_previous_text: bool = False
    no_speech_threshold: float = 0.6
    compression_ratio_threshold: float = 2.4
    logprob_threshold: float = -1.0
    temperature: tuple[float, ...] = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
    use_vad: bool = False

    @staticmethod
    def from_params(params: dict[str, Any]) -> TranscribeOptions:
        defaults = TranscribeOptions()
        temperature = params.get("temperature")
        return TranscribeOptions(
            model=params.get("model") or defaults.model,
            language=params.get("language") or defaults.language,
            initial_prompt=params.get("initial_prompt"),
            condition_on_previous_text=bool(
                params.get("condition_on_previous_text", defaults.condition_on_previous_text)),
            no_speech_threshold=float(
                params.get("no_speech_threshold", defaults.no_speech_threshold)),
            compression_ratio_threshold=float(
                params.get("compression_ratio_threshold", defaults.compression_ratio_threshold)),
            logprob_threshold=float(params.get("logprob_threshold", defaults.logprob_threshold)),
            temperature=tuple(temperature) if temperature else defaults.temperature,
            use_vad=bool(params.get("vad", defaults.use_vad)),
        )


@dataclass
class Segment:
    start: float
    end: float
    text: str
    avg_logprob: float = 0.0
    no_speech_prob: float = 0.0
    compression_ratio: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "text": self.text,
            "avg_logprob": self.avg_logprob,
            "no_speech_prob": self.no_speech_prob,
            "compression_ratio": self.compression_ratio,
        }


@dataclass
class TranscribeResult:
    segments: list[Segment] = field(default_factory=list)
    model: str = DEFAULT_MODEL
    elapsed: float = 0.0
    audio_duration: float = 0.0
    speech_ratio: float = 1.0

    @property
    def text(self) -> str:
        return "".join(s.text for s in self.segments)

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "segments": [s.to_dict() for s in self.segments],
            "model": self.model,
            "elapsed": round(self.elapsed, 3),
            "audio_duration": round(self.audio_duration, 3),
            "speech_ratio": round(self.speech_ratio, 3),
        }


class WhisperEngine:
    """モデルを読み込んだまま常駐し、繰り返し呼ばれる前提。"""

    def __init__(self) -> None:
        self._loaded_model: str | None = None

    @property
    def loaded_model(self) -> str | None:
        return self._loaded_model

    def load(self, model: str = DEFAULT_MODEL) -> None:
        """モデルを取得して常駐させる。

        mlx_whisper は明示的なロード API を持たず、初回の transcribe で
        ダウンロードと読み込みが走る。無音を 1 回通して暖機しておくことで、
        最初の実測値にダウンロード時間が混ざるのを防ぐ。
        """
        import mlx_whisper

        warmup = np.zeros(SAMPLE_RATE, dtype=np.float32)
        mlx_whisper.transcribe(
            warmup, path_or_hf_repo=model, language="ja", verbose=False)
        self._loaded_model = model

    def transcribe_file(self, path: str | Path, options: TranscribeOptions) -> TranscribeResult:
        audio = self._load_audio(Path(path))
        return self.transcribe_samples(audio, options)

    def transcribe_samples(
        self, samples: np.ndarray, options: TranscribeOptions
    ) -> TranscribeResult:
        started = time.monotonic()
        duration = samples.size / SAMPLE_RATE

        if options.use_vad:
            segments, ratio = self._transcribe_with_vad(samples, options)
        else:
            segments = self._transcribe_whole(samples, options, offset=0.0)
            ratio = 1.0

        self._loaded_model = options.model
        return TranscribeResult(
            segments=segments,
            model=options.model,
            elapsed=time.monotonic() - started,
            audio_duration=duration,
            speech_ratio=ratio,
        )

    # -- 内部 ---------------------------------------------------------------

    def _transcribe_with_vad(
        self, samples: np.ndarray, options: TranscribeOptions
    ) -> tuple[list[Segment], float]:
        """発話区間だけを切り出して個別に投入する。

        無音を渡さないので、無音に対するでっち上げが構造的に起きない。
        タイムスタンプは元の音声の時間軸に戻す。
        """
        speech = vad.detect_speech(samples, SAMPLE_RATE)
        duration = samples.size / SAMPLE_RATE
        if not speech:
            return [], 0.0

        segments: list[Segment] = []
        for region in speech:
            start_index = int(region.start * SAMPLE_RATE)
            end_index = min(samples.size, int(region.end * SAMPLE_RATE))
            chunk = samples[start_index:end_index]
            if chunk.size == 0:
                continue
            segments.extend(self._transcribe_whole(chunk, options, offset=region.start))

        return segments, vad.speech_ratio(speech, duration)

    def _transcribe_whole(
        self, samples: np.ndarray, options: TranscribeOptions, offset: float
    ) -> list[Segment]:
        import mlx_whisper

        result = mlx_whisper.transcribe(
            samples,
            path_or_hf_repo=options.model,
            language=options.language,
            initial_prompt=options.initial_prompt,
            condition_on_previous_text=options.condition_on_previous_text,
            no_speech_threshold=options.no_speech_threshold,
            compression_ratio_threshold=options.compression_ratio_threshold,
            logprob_threshold=options.logprob_threshold,
            temperature=options.temperature,
            verbose=False,
        )

        segments: list[Segment] = []
        for raw in result.get("segments", []):
            text = (raw.get("text") or "").strip()
            if not text:
                continue
            segments.append(
                Segment(
                    start=float(raw.get("start", 0.0)) + offset,
                    end=float(raw.get("end", 0.0)) + offset,
                    text=text,
                    avg_logprob=float(raw.get("avg_logprob", 0.0)),
                    no_speech_prob=float(raw.get("no_speech_prob", 0.0)),
                    compression_ratio=float(raw.get("compression_ratio", 0.0)),
                ))
        return segments

    @staticmethod
    def _load_audio(path: Path) -> np.ndarray:
        """16kHz モノラルの float32 として読む。

        `mlx_whisper.audio.load_audio` は mlx の配列を返す。VAD は numpy 前提
        なので、ここで numpy に寄せておく（mlx の配列には `astype(np.float64)`
        のような numpy の呼び出し規約がそのままは通らない）。
        """
        if not path.exists():
            raise FileNotFoundError(f"音声ファイルが見つかりません: {path}")

        import mlx_whisper.audio as audio_module

        audio = audio_module.load_audio(str(path), sr=SAMPLE_RATE)
        return np.asarray(audio, dtype=np.float32)
