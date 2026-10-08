import AudioRecKit
import AVFoundation
import Foundation
import Observation

enum RecordingSessionError: LocalizedError {
    case joinFailed(String)

    var errorDescription: String? {
        switch self {
        case .joinFailed(let detail):
            "続きの音声を録音本体へつなげませんでした。"
                + "音声は消えずに残っており、次に続きを録音するときにもう一度つなぎます: \(detail)"
        }
    }
}

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

    /// 録音セッションが動いているか。一時停止中も true。
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// 停止後、文字起こしの確定と音声の結合を待っている間。
    private(set) var isSaving = false
    /// 録音全体の頭からの経過秒数。続きから録るときは前回までの長さから数える。
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
    /// 今回の録音が録音全体の何秒目から始まるか。新しい録音なら 0。
    /// エンジンが返す時刻は「今回の頭から」なので、これを足して全体の時刻にする。
    private var baseOffset: TimeInterval = 0
    /// 既存の音声の後ろへ続けて録っているか。
    private var isAppending = false
    /// 前回までに録ったトラック。今回のトラックと合わせて meta に残す。
    private var baseTracks: [TrackKind] = []
    /// 今回、一時停止を除いて録った秒数（直近の再開より前の分）。
    private var accumulated: TimeInterval = 0
    /// 直近に録音を始めた / 再開した時刻。一時停止中は nil。
    private var activeSince: Date?
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
        try await requestMicPermission()

        let meta = try await store.create(title: title ?? Self.defaultTitle())
        do {
            return try await begin(
                meta: meta, appending: false, baseOffset: 0, baseTranscript: .empty,
                engineKind: engineKind, captureSystemAudio: captureSystemAudio)
        } catch {
            // 録音が始まらなかった空のディレクトリを残さない
            try? await store.delete(meta.id)
            throw error
        }
    }

    /// 既存の録音に録音する。音声があればその続きに、無ければ頭から録る。
    ///
    /// 録音せずに作った「空の録音」に後から録るのも、一度止めた録音を
    /// 続きから録り直すのもここを通る。
    func start(
        into id: String,
        engineKind: ASREngineKind = .apple,
        captureSystemAudio: Bool = true
    ) async throws -> RecordingMeta {
        guard !isRecording else { throw MicRecorderError.alreadyRecording }
        try await requestMicPermission()

        var meta = try await store.loadMeta(id)
        let paths = store.paths

        // 前回の続きがつながないまま残っていたら（途中で落ちた等）、先に回収する
        if FileManager.default.fileExists(atPath: paths.pendingAudioFile(id, track: .mic).path) {
            let recovered = try await Self.commitPending(id: id, paths: paths)
            meta = meta.with(duration: recovered)
            try await store.saveMeta(meta)
        }

        let micFile = paths.audioFile(id, track: .mic)
        let appending = FileManager.default.fileExists(atPath: micFile.path)
        // 前回までの長さは meta ではなく実ファイルから測る。
        // 続きの音声はこの直後に置くので、ここがずれると文字起こしの時刻もずれる。
        let baseOffset = appending ? try AudioAppender.duration(of: micFile) : 0

        do {
            return try await begin(
                meta: meta, appending: appending, baseOffset: baseOffset,
                baseTranscript: await store.loadTranscript(id),
                engineKind: engineKind, captureSystemAudio: captureSystemAudio)
        } catch {
            // 書きかけのファイルを残すと、次に「音声あり」と誤認する
            Self.discardAudio(id: id, paths: paths, appending: appending)
            throw error
        }
    }

    /// 一時停止する。止めている間の音声はファイルにも文字起こしにも入らない。
    func pause() {
        guard isRecording, !isPaused, !isSaving else { return }
        recorder.pause()
        if let activeSince { accumulated += Date().timeIntervalSince(activeSince) }
        activeSince = nil
        isPaused = true
        volatileText = ""
        refreshElapsed()
    }

    /// 一時停止から再開する。
    func resume() throws {
        guard isRecording, isPaused, !isSaving else { return }
        try recorder.resume()
        activeSince = Date()
        isPaused = false
    }

    /// 録音を止め、実測の長さと最終的な文字起こしを書き込んだメタデータを返す。
    @discardableResult
    func stop() async throws -> RecordingMeta? {
        guard isRecording, !isSaving, let id = currentID else { return nil }

        let recorded = recorder.stop()
        stopTimer()
        isSaving = true
        // 保存に失敗しても「録音中」のまま固まらないよう、状態は必ず戻す
        defer { resetState() }

        // 残っている音声を確定させてから片付ける。ここを待たないと最後の発話が落ちる。
        await teardownTranscription()

        let finalTranscript = liveTranscript.sorted()
        try await store.saveTranscript(finalTranscript, for: id)

        var duration = baseOffset + recorded
        if isAppending {
            do {
                duration = try await Self.commitPending(id: id, paths: store.paths)
            } catch {
                throw RecordingSessionError.joinFailed(error.localizedDescription)
            }
        }

        let tracks = TrackKind.allCases.filter { baseTracks.contains($0) || activeTracks.contains($0) }
        let updated = try await store.loadMeta(id).with(duration: duration, tracks: tracks)
        try await store.saveMeta(updated)
        return updated
    }

    // MARK: - 開始の共通部分

    private func requestMicPermission() async throws {
        let permission = await MicPermission.request()
        guard permission == .granted else { throw MicRecorderError.permissionDenied }
    }

    private func begin(
        meta: RecordingMeta,
        appending: Bool,
        baseOffset: TimeInterval,
        baseTranscript: Transcript,
        engineKind: ASREngineKind,
        captureSystemAudio: Bool
    ) async throws -> RecordingMeta {
        // 準備 → エンジン起動 → 録音開始 の順に進める。
        // 先に録音を始めてしまうと、タップ生成やモデル読み込みにかかる 1 秒前後の
        // 音声がマイクにだけ入り、2 トラックの長さがずれ、その間の発話も
        // ライブ文字起こしから抜け落ちる。
        do {
            activeTracks = try recorder.prepare(
                paths: store.paths, recordingID: meta.id,
                captureSystemAudio: captureSystemAudio, appending: appending)
            try await startTranscription(engineKind: engineKind)
            try recorder.start()
            activeTracks = recorder.activeTracks
        } catch {
            recorder.stop()
            await teardownTranscription()
            activeTracks = []
            throw error
        }

        currentID = meta.id
        isRecording = true
        isPaused = false
        isAppending = appending
        self.baseOffset = baseOffset
        baseTracks = appending ? meta.tracks : []
        accumulated = 0
        activeSince = Date()
        elapsed = baseOffset
        levels = []
        // 続きから録るときは、前回までの文字起こしの後ろに足していく
        liveTranscript = baseTranscript.sorted()
        volatileText = ""
        startTimer()

        let tracks = TrackKind.allCases.filter { baseTracks.contains($0) || activeTracks.contains($0) }
        let updated = meta.with(tracks: tracks, engine: engineKind)
        try? await store.saveMeta(updated)
        return updated
    }

    private func resetState() {
        isRecording = false
        isPaused = false
        isSaving = false
        isAppending = false
        currentID = nil
        baseOffset = 0
        baseTracks = []
        accumulated = 0
        activeSince = nil
        elapsed = 0
        levels = []
        volatileText = ""
        activeTracks = []
    }

    /// 音声の結合は 1 時間の録音で十数秒かかる。UI を止めないよう外で回す。
    private static func commitPending(id: String, paths: StoragePaths) async throws -> TimeInterval {
        try await Task.detached(priority: .userInitiated) {
            try AudioAppender.commitPending(id: id, paths: paths)
        }.value
    }

    /// 始められなかった録音の書きかけを消す。
    private static func discardAudio(id: String, paths: StoragePaths, appending: Bool) {
        for track in TrackKind.allCases {
            let files =
                appending
                ? [paths.pendingAudioFile(id, track: track), paths.pendingASRAudioFile(id, track: track)]
                : [paths.audioFile(id, track: track), paths.asrAudioFile(id, track: track)]
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
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
            liveTranscript = liveTranscript.appending(segment.shifted(by: baseOffset)).sorted()
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
            Task { @MainActor in self?.refreshElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshElapsed() {
        let running = activeSince.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = baseOffset + accumulated + running
    }

    private static func defaultTitle(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm の録音"
        return f.string(from: now)
    }
}
