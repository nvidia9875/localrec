import AudioRecKit
import AVFoundation
import Foundation
import Observation

/// 録音中の状態を持つ。AppModel から切り出して、録音の関心事をここに閉じ込める。
///
/// 2 トラック録音のときは、トラックごとに独立した文字起こしエンジンを走らせる。
/// 混ぜた音声を 1 つのエンジンに渡すより精度が高く、どちらのトラック由来かが
/// そのまま話者ラベルになる。
@MainActor
@Observable
final class RecordingSession {

    /// 波形バーの本数。多すぎると再描画コストが上がるだけで見た目は変わらない。
    private static let levelHistoryCount = 64

    // MARK: - 公開状態

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var currentID: String?
    private(set) var activeTracks: [TrackKind] = []

    /// 確定した文字起こし。録音中も逐次伸びていく。
    private(set) var liveTranscript: Transcript = .empty
    /// まだ確定していないテキスト。UI では薄く出し、確定したら消える。
    private(set) var volatileText: String = ""
    /// モデル資産のダウンロード進捗 (0...1)。不要なときは nil。
    private(set) var modelDownloadProgress: Double?

    /// 録音中に起きたエラーを外へ伝える。握り潰さない。
    var onError: ((String) -> Void)?

    // MARK: - 設定

    private var glossary: Glossary = .empty
    /// Whisper を使うときのモデル。既定は eval のベンチ結果で選ぶ。
    private var whisperModel: String = MLXWhisperEngine.defaultModel

    // MARK: - 依存

    private let store: RecordingStore
    private let recorder = DualTrackRecorder()
    private var engines: [TrackKind: any ASREngine] = [:]

    // MARK: - 内部状態

    private var timer: Timer?
    private var startedAt: Date?
    /// オーディオスレッドからエンジンへバッファを渡す直列チャネル（トラックごと）。
    /// バッファごとに Task を立てると順序が入れ替わり、認識結果が壊れる。
    private var bufferContinuations: [TrackKind: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]
    private var feedTasks: [TrackKind: Task<Void, Never>] = [:]
    private var eventTasks: [TrackKind: Task<Void, Never>] = [:]

    init(store: RecordingStore) {
        self.store = store

        recorder.onLevel = { [weak self] level, track in
            // 波形はマイク側だけを出す。2 本重ねても読み取れない。
            guard track == .mic else { return }
            self?.appendLevel(level)
        }
        recorder.onError = { [weak self] error, track in
            self?.onError?("[\(track.rawValue)] \(error.localizedDescription)")
        }
        recorder.onASRBuffer = { [weak self] buffer, track, _ in
            // オーディオスレッドから呼ばれる。yield は軽く、順序も保たれる。
            self?.bufferContinuations[track]?.yield(buffer)
        }
    }

    func setGlossary(_ glossary: Glossary) {
        self.glossary = glossary
    }

    func setWhisperModel(_ model: String) {
        self.whisperModel = model
    }

    // MARK: - 開始 / 停止

    /// 新しい録音を作って開始し、そのメタデータを返す。
    func start(
        title: String? = nil,
        engineKind: ASREngineKind = .apple,
        captureSystemAudio: Bool = true
    ) async throws -> RecordingMeta {
        guard !isRecording else { throw MicRecorderError.alreadyRecording }

        let permission = await MicPermission.request()
        guard permission == .granted else { throw MicRecorderError.permissionDenied }

        let meta = try await store.create(title: title ?? Self.defaultTitle())

        // 準備 → エンジン起動 → 録音開始 の順に進める。
        // 先に録音を始めてしまうと、タップ生成やモデル読み込みにかかる 1 秒前後の
        // 音声がマイクにだけ入り、2 トラックの長さがずれ、その間の発話も
        // ライブ文字起こしから抜け落ちる。
        do {
            activeTracks = try recorder.prepare(
                paths: store.paths, recordingID: meta.id, captureSystemAudio: captureSystemAudio)
            try await startTranscription(engineKind: engineKind)
            try recorder.start()
            activeTracks = recorder.activeTracks
        } catch {
            recorder.stop()
            await teardownTranscription()
            // 録音が始まらなかった空のディレクトリを残さない
            try? await store.delete(meta.id)
            throw error
        }

        currentID = meta.id
        isRecording = true
        elapsed = 0
        levels = []
        liveTranscript = .empty
        volatileText = ""
        startedAt = Date()
        startTimer()

        let updated = meta.with(tracks: activeTracks, engine: engineKind)
        try? await store.saveMeta(updated)
        return updated
    }

    /// 録音を止め、実測の長さと最終的な文字起こしを書き込んだメタデータを返す。
    @discardableResult
    func stop() async throws -> RecordingMeta? {
        guard isRecording, let id = currentID else { return nil }

        let duration = recorder.stop()
        stopTimer()

        // 残っている音声を確定させてから片付ける。ここを待たないと最後の発話が落ちる。
        await teardownTranscription()

        let finalTranscript = liveTranscript.sorted()
        try await store.saveTranscript(finalTranscript, for: id)

        let updated = try await store.loadMeta(id).with(duration: duration, tracks: activeTracks)
        try await store.saveMeta(updated)

        isRecording = false
        currentID = nil
        startedAt = nil
        elapsed = 0
        levels = []
        volatileText = ""
        activeTracks = []
        return updated
    }

    // MARK: - 文字起こし

    /// トラックごとにエンジンを立ち上げる。
    private func startTranscription(engineKind: ASREngineKind) async throws {
        for track in activeTracks {
            let engine = try await makeEngine(kind: engineKind)
            engines[track] = engine

            let events = try await engine.startLive(speaker: speaker(for: track))

            let (buffers, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            bufferContinuations[track] = continuation

            // 1 本の Task で順に投入することで、到着順を保つ
            feedTasks[track] = Task {
                for await buffer in buffers {
                    await engine.feed(buffer)
                }
            }

            eventTasks[track] = Task { [weak self] in
                for await event in events {
                    await self?.handle(event, from: track)
                }
            }
        }
    }

    /// 単一トラックのときは話者を決められない。
    /// 「自分」と書いてしまうと、対面録音で相手の発言まで自分の扱いになる。
    private func speaker(for track: TrackKind) -> SpeakerRole {
        guard activeTracks.count > 1 else { return .unknown }
        return track == .mic ? .mySelf : .other
    }

    private func makeEngine(kind: ASREngineKind) async throws -> any ASREngine {
        let engine: any ASREngine =
            switch kind {
            case .apple: AppleSpeechEngine(glossary: glossary)
            case .mlx: MLXWhisperEngine(model: whisperModel, glossary: glossary)
            }

        switch await engine.readiness() {
        case .ready:
            return engine
        case .needsDownload:
            // 初回はモデルの取得に時間がかかる。無言で待たせない。
            modelDownloadProgress = 0
            defer { modelDownloadProgress = nil }
            try await engine.prepare(progress: { [weak self] fraction in
                Task { @MainActor in self?.modelDownloadProgress = fraction }
            })
            return engine
        case .unsupported(let reason):
            throw ASREngineError.engineFailure(reason)
        }
    }

    private func handle(_ event: ASREvent, from track: TrackKind) async {
        switch event {
        case .volatile(let text):
            // 未確定テキストはマイク側だけを出す。2 トラック分を混ぜると読めない。
            if track == .mic { volatileText = text }

        case .finalized(let segment):
            liveTranscript = liveTranscript.appending(segment).sorted()
            if track == .mic { volatileText = "" }
            // 確定するたびに保存する。途中でアプリが落ちても書き起こしが残る。
            if let id = currentID {
                do {
                    try await store.saveTranscript(liveTranscript, for: id)
                } catch {
                    onError?("文字起こしを保存できませんでした: \(error.localizedDescription)")
                }
            }
        }
    }

    private func teardownTranscription() async {
        for (_, continuation) in bufferContinuations { continuation.finish() }
        bufferContinuations.removeAll()

        for (_, task) in feedTasks { await task.value }
        feedTasks.removeAll()

        for (_, engine) in engines { await engine.finishLive() }

        for (_, task) in eventTasks { await task.value }
        eventTasks.removeAll()

        engines.removeAll()
        volatileText = ""
    }

    // MARK: - 内部

    private func appendLevel(_ level: Float) {
        levels.append(level)
        if levels.count > Self.levelHistoryCount {
            levels.removeFirst(levels.count - Self.levelHistoryCount)
        }
    }

    private func startTimer() {
        // 経過時間の表示更新だけなので 0.1 秒で十分。
        // 保存される長さは録音済みフレーム数から別途算出するのでここの精度は問わない。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func defaultTitle(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm の録音"
        return f.string(from: now)
    }
}
