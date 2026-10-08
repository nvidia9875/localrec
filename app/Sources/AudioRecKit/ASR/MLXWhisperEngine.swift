import AVFoundation
import Foundation

/// mlx-whisper サイドカーを使う文字起こしエンジン。
///
/// Whisper はファイル単位で動くため、Apple の SpeechAnalyzer のような
/// 真のストリーミングにはならない。無音を境に発話のかたまりを切り出し、
/// かたまりが確定するたびに投げる「疑似ライブ」で動かす。
/// 文の途中で切らないので精度への影響を抑えられ、無音を渡さないことで
/// Whisper の定型句ハルシネーションも起きにくくなる。
public actor MLXWhisperEngine: ASREngine {

    public nonisolated let kind: ASREngineKind = .mlx

    /// eval のベンチ（80文 × 5条件）で決めた既定モデル。
    ///
    /// large-v3 より turbo の方が CER も RTF も良かった（3.83% / 0.051 対 3.88% / 0.104）。
    /// 日本語特化の kotoba-whisper-v2.0 は 4.45% で最下位だったため採用しない。
    public static let defaultModel = "mlx-community/whisper-large-v3-turbo"

    private let sidecar: SidecarProcess?
    private let model: String
    private var glossary: Glossary

    private var eventContinuation: AsyncStream<ASREvent>.Continuation?
    private var chunker = SpeechChunker()
    private var speaker: SpeakerRole = .unknown
    /// かたまりの文字起こしを 1 本の連鎖にして、サイドカーへの同時投入を避ける。
    private var transcriptionChain: Task<Void, Never>?
    private var temporaryDirectory: URL?

    public init(
        model: String = MLXWhisperEngine.defaultModel,
        glossary: Glossary = .empty,
        location: SidecarProcess.Location? = SidecarProcess.Location.discover()
    ) {
        self.model = model
        self.glossary = glossary
        self.sidecar = location.map { SidecarProcess(location: $0) }
    }

    public func setGlossary(_ glossary: Glossary) {
        self.glossary = glossary
    }

    // MARK: - 準備

    public func readiness() async -> ASRReadiness {
        guard let sidecar else {
            return .unsupported(
                reason: "Whisper サイドカーが見つかりません。sidecar/.venv を作成してください。")
        }
        do {
            let response = try await sidecar.call("ping")
            guard response.ok == true else {
                return .unsupported(reason: response.error?.message ?? "応答が不正です")
            }
            // モデルが未ロードなら初回に取得が要る
            return response.result?.model == model ? .ready : .needsDownload
        } catch {
            return .unsupported(reason: error.localizedDescription)
        }
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        guard let sidecar else { throw SidecarError.notInstalled }
        // サイドカーはダウンロードの進捗を返さないので、
        // 完了したことだけを伝える。無言で待たせるよりはよい。
        progress?(0)
        let response = try await sidecar.call("load", params: SidecarParams(model: model))
        guard response.ok == true else {
            throw SidecarError.remote(response.error?.message ?? "モデルを読み込めませんでした")
        }
        progress?(1)
    }

    // MARK: - ライブ（疑似）

    public func startLive(speaker: SpeakerRole) async throws -> AsyncStream<ASREvent> {
        guard let sidecar else { throw SidecarError.notInstalled }
        guard eventContinuation == nil else { throw ASREngineError.alreadyRunning }

        try await sidecar.start()
        self.speaker = speaker
        chunker = SpeechChunker()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiorec-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory

        let (events, continuation) = AsyncStream<ASREvent>.makeStream()
        eventContinuation = continuation
        return events
    }

    public func feed(_ buffer: AVAudioPCMBuffer) async {
        guard eventContinuation != nil else { return }
        guard let samples = Self.floatSamples(from: buffer) else { return }

        for chunk in chunker.append(samples) {
            enqueue(chunk)
        }
    }

    public func finishLive() async {
        if let chunk = chunker.flush() {
            enqueue(chunk)
        }
        // 連鎖の最後まで待ってから閉じる。待たないと末尾の発話が落ちる。
        await transcriptionChain?.value
        transcriptionChain = nil

        eventContinuation?.finish()
        eventContinuation = nil

        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        await sidecar?.stop()
    }

    /// かたまりの文字起こしを直列に積む。
    private func enqueue(_ chunk: SpeechChunker.Chunk) {
        let previous = transcriptionChain
        transcriptionChain = Task { [weak self] in
            await previous?.value
            await self?.transcribe(chunk)
        }
    }

    private func transcribe(_ chunk: SpeechChunker.Chunk) async {
        guard let sidecar, let temporaryDirectory else { return }

        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try Self.writeWAV(samples: chunk.samples, to: url)
            let response = try await sidecar.call(
                "transcribe_file",
                params: SidecarParams(
                    path: url.path, model: model, language: "ja",
                    initial_prompt: glossary.whisperPrompt(), vad: false))

            guard response.ok == true, let result = response.result else {
                emitError(response.error?.message ?? "文字起こしに失敗しました")
                return
            }
            for segment in makeSegments(from: result, offset: chunk.start) {
                eventContinuation?.yield(.finalized(segment))
            }
        } catch {
            emitError(error.localizedDescription)
        }
    }

    private func emitError(_ message: String) {
        // 無言で結果が来なくなる状態を作らない
        eventContinuation?.yield(.volatile("[エラー] \(message)"))
    }

    // MARK: - ファイル一括

    public func transcribeFile(at url: URL, speaker: SpeakerRole) async throws -> Transcript {
        guard let sidecar else { throw SidecarError.notInstalled }
        try await sidecar.start()

        let response = try await sidecar.call(
            "transcribe_file",
            params: SidecarParams(
                path: url.path, model: model, language: "ja",
                initial_prompt: glossary.whisperPrompt(), vad: true))

        guard response.ok == true, let result = response.result else {
            throw SidecarError.remote(response.error?.message ?? "文字起こしに失敗しました")
        }
        self.speaker = speaker
        return Transcript(segments: makeSegments(from: result, offset: 0)).sorted()
    }

    // MARK: - 変換

    private func makeSegments(from result: SidecarResult, offset: TimeInterval) -> [TranscriptSegment] {
        (result.segments ?? []).compactMap { raw in
            let text = JapaneseText.tidy(raw.text)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: raw.start + offset,
                end: raw.end + offset,
                speaker: speaker,
                text: glossary.applyCorrections(to: text),
                confidence: raw.avg_logprob.map(Self.confidence(fromAverageLogProb:)),
                engine: .mlx
            )
        }
    }

    /// Whisper が返す平均対数確率を 0...1 の信頼度に均す。
    ///
    /// exp() をそのまま使うと大半が 0.9 以上に張り付いて差が見えないため、
    /// 実用上意味のある範囲（-1.0 〜 0.0）を線形に伸ばす。
    static func confidence(fromAverageLogProb value: Double) -> Double {
        let floor = -1.0
        return min(1.0, max(0.0, (value - floor) / -floor))
    }

    static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// 16kHz モノラルの WAV として書き出す。サイドカーはファイル経由で受け取る。
    static func writeWAV(samples: [Float], to url: URL) throws {
        let format = AudioResampler.asrFormat()
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioResampler.asrFileSettings(),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw AudioResamplerError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
