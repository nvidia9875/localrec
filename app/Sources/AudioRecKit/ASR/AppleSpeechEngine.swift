import AVFoundation
import Foundation
import Speech

/// macOS 26 の `SpeechAnalyzer` を使う文字起こしエンジン。
///
/// 完全にオンデバイスで動き、ローカル LLM を必要としない。
/// `volatileResults` により、話している最中から未確定テキストが流れてくる。
public actor AppleSpeechEngine: ASREngine {

    public nonisolated let kind: ASREngineKind = .apple

    private let requestedLocale: Locale
    private var glossary: Glossary

    // ライブ実行中の状態
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<ASREvent>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var resampler: AudioResampler?
    private var resamplerInputFormat: AVAudioFormat?
    private var speaker: SpeakerRole = .unknown

    public init(locale: Locale = Locale(identifier: "ja-JP"), glossary: Glossary = .empty) {
        self.requestedLocale = locale
        self.glossary = glossary
    }

    public func setGlossary(_ glossary: Glossary) {
        self.glossary = glossary
    }

    // MARK: - 準備

    public func readiness() async -> ASRReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unsupported(reason: "この Mac では音声認識を利用できません")
        }
        guard let locale = await resolvedLocale() else {
            return .unsupported(reason: "\(requestedLocale.identifier(.bcp47)) には対応していません")
        }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale: locale, live: false)]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsDownload
        case .unsupported:
            return .unsupported(reason: "音声認識モデルを利用できません")
        @unknown default:
            return .unsupported(reason: "音声認識モデルの状態を判別できませんでした")
        }
    }

    /// 必要ならモデル資産をダウンロードする。数百 MB になるので進捗を返す。
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        guard let locale = await resolvedLocale() else {
            throw ASREngineError.localeNotSupported(requestedLocale.identifier(.bcp47))
        }

        let module = makeTranscriber(locale: locale, live: false)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            // Progress の KVO は Sendable 周りが煩雑なので、素直に間隔を空けて読む。
            let reporter = progress.map { callback in
                Task {
                    while !Task.isCancelled {
                        callback(request.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
            defer { reporter?.cancel() }

            try await request.downloadAndInstall()
            progress?(1.0)
        }

        // 予約しておくと OS がモデルを保持し続けてくれる (上限 5 ロケール)。
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - ライブ文字起こし

    public func startLive(speaker: SpeakerRole) async throws -> AsyncStream<ASREvent> {
        guard analyzer == nil else { throw ASREngineError.alreadyRunning }
        guard let locale = await resolvedLocale() else {
            throw ASREngineError.localeNotSupported(requestedLocale.identifier(.bcp47))
        }

        self.speaker = speaker
        let transcriber = makeTranscriber(locale: locale, live: true)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw ASREngineError.audioFormatUnavailable }
        analyzerFormat = format
        resampler = nil
        resamplerInputFormat = nil

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse),
            analysisContext: makeContext()
        )
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)

        let (events, eventContinuation) = AsyncStream<ASREvent>.makeStream()
        self.eventContinuation = eventContinuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.emit(result)
                }
            } catch {
                await self?.emitFailure(error)
            }
            eventContinuation.finish()
        }

        return events
    }

    public func feed(_ buffer: AVAudioPCMBuffer) async {
        guard let inputContinuation, let analyzerFormat else { return }

        do {
            let prepared = try convert(buffer, to: analyzerFormat)
            inputContinuation.yield(AnalyzerInput(buffer: prepared))
        } catch {
            emitFailure(error)
        }
    }

    public func finishLive() async {
        inputContinuation?.finish()
        inputContinuation = nil

        // 入力終端まで解析させてから結果ストリームの終了を待つ。
        // ここを待たないと最後の発話が落ちる。
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value

        resultsTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        resampler = nil
        resamplerInputFormat = nil
    }

    // MARK: - ファイル一括

    public func transcribeFile(at url: URL, speaker: SpeakerRole) async throws -> Transcript {
        guard let locale = await resolvedLocale() else {
            throw ASREngineError.localeNotSupported(requestedLocale.identifier(.bcp47))
        }

        let transcriber = makeTranscriber(locale: locale, live: false)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ASREngineError.engineFailure("音声ファイルを開けませんでした: \(error.localizedDescription)")
        }

        // analyzer は結果を読み終えるまで保持し続ける必要がある
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file,
            modules: [transcriber],
            analysisContext: makeContext(),
            finishAfterFile: true
        )

        var segments: [TranscriptSegment] = []
        do {
            for try await result in transcriber.results where result.isFinal {
                segments.append(contentsOf: makeSegments(from: result, speaker: speaker))
            }
        } catch {
            throw ASREngineError.engineFailure(error.localizedDescription)
        }
        withExtendedLifetime(analyzer) {}

        return Transcript(segments: segments).sorted()
    }

    // MARK: - 内部

    private func resolvedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
    }

    /// ライブ時だけ volatileResults を付ける。
    /// ファイル一括では未確定結果は捨てるだけなので、要求すると無駄に処理が増える。
    private func makeTranscriber(locale: Locale, live: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    /// 用語辞書を認識のヒントとして渡す。固有名詞の精度に効く。
    private func makeContext() -> AnalysisContext {
        let context = AnalysisContext()
        if !glossary.terms.isEmpty {
            context.contextualStrings[.general] = glossary.terms
        }
        return context
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }

        if resampler == nil || resamplerInputFormat != buffer.format {
            guard let created = AudioResampler(inputFormat: buffer.format, outputFormat: format) else {
                throw ASREngineError.conversionFailed("変換器を作成できませんでした")
            }
            resampler = created
            resamplerInputFormat = buffer.format
        }
        guard let converted = try resampler?.resample(buffer) else {
            throw ASREngineError.conversionFailed("変換結果が空でした")
        }
        return converted
    }

    private func emit(_ result: SpeechTranscriber.Result) {
        let raw = String(result.text.characters)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if result.isFinal {
            for segment in makeSegments(from: result, speaker: speaker) {
                eventContinuation?.yield(.finalized(segment))
            }
        } else {
            eventContinuation?.yield(.volatile(JapaneseText.tidy(raw)))
        }
    }

    private func emitFailure(_ error: Error) {
        // ストリームを閉じることで、購読側が「途中で止まった」と分かる。
        // 無言で結果が来なくなる状態を作らない。
        eventContinuation?.yield(
            .volatile("[エラー] \(error.localizedDescription)"))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// 1 つの認識結果を、文単位のセグメントに割る。
    ///
    /// エンジンは 10 秒分をまとめて 1 結果として返してくることがある。
    /// そのまま 1 行にすると行ごとのタイムスタンプが機能しないので、
    /// 語ごとの時間属性を使って文末で切り直す。
    private func makeSegments(
        from result: SpeechTranscriber.Result, speaker: SpeakerRole
    ) -> [TranscriptSegment] {
        let confidence = Self.averageConfidence(of: result.text)
        let tokens = Self.timedTokens(from: result.text)

        // 時間属性が取れなかった場合は、結果全体を 1 セグメントとして扱う
        let sentences: [TimedToken] = tokens.isEmpty
            ? [
                TimedToken(
                    text: String(result.text.characters),
                    start: result.range.start.seconds,
                    end: result.range.end.seconds)
            ]
            : SentenceGrouper.group(tokens)

        return sentences.compactMap { sentence in
            let text = JapaneseText.tidy(sentence.text)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: sentence.start,
                end: sentence.end,
                speaker: speaker,
                text: glossary.applyCorrections(to: text),
                confidence: confidence,
                engine: .apple
            )
        }
    }

    /// AttributedString の run から、時間付きトークンを取り出す。
    ///
    /// 時間属性を持たない run (記号など) は直前のトークンに連結する。
    /// 単独で落とすと句読点が消えてしまう。
    static func timedTokens(from text: AttributedString) -> [TimedToken] {
        var tokens: [TimedToken] = []
        var pending = ""

        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }

            guard let range = run.audioTimeRange else {
                pending += piece
                continue
            }

            let merged = pending + piece
            pending = ""
            tokens.append(
                TimedToken(
                    text: merged,
                    start: range.start.seconds,
                    end: range.end.seconds))
        }

        // 末尾に残った記号は最後のトークンに付ける
        if !pending.isEmpty, let last = tokens.popLast() {
            tokens.append(TimedToken(text: last.text + pending, start: last.start, end: last.end))
        }
        return tokens
    }

    /// 信頼度は語ごとに付くので、文字数で重み付けして 1 セグメント分に均す。
    /// 単純平均だと 1 文字の助詞が長い固有名詞と同じ重みになってしまう。
    static func averageConfidence(of text: AttributedString) -> Double? {
        var weightedSum = 0.0
        var totalLength = 0

        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let length = text[run.range].characters.count
            guard length > 0 else { continue }
            weightedSum += confidence * Double(length)
            totalLength += length
        }

        return totalLength > 0 ? weightedSum / Double(totalLength) : nil
    }
}
