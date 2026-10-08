import Foundation

/// Python サイドカーとの stdio NDJSON 通信。
///
/// HTTP ではなくパイプを使う理由:
/// - ポートを開かないので衝突もファイアウォールの警告も起きない
/// - 認証を考えなくてよい（親プロセスしか話しかけられない）
/// - アプリが終われば stdin が閉じ、サイドカーも確実に道連れになる
public actor SidecarProcess {

    public struct Location: Sendable {
        public let python: URL
        public let sourceRoot: URL
        public let workingDirectory: URL

        public init(python: URL, sourceRoot: URL, workingDirectory: URL) {
            self.python = python
            self.sourceRoot = sourceRoot
            self.workingDirectory = workingDirectory
        }

        /// 既定の探索順。
        /// 1. 環境変数 `AUDIOREC_SIDECAR_ROOT`
        /// 2. アプリバンドル内の Resources/sidecar（配布時）
        /// 3. 開発中のリポジトリ配置
        public static func discover(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundle: Bundle = .main
        ) -> Location? {
            var candidates: [URL] = []

            if let override = environment["AUDIOREC_SIDECAR_ROOT"] {
                candidates.append(URL(fileURLWithPath: override, isDirectory: true))
            }
            if let resources = bundle.resourceURL {
                candidates.append(resources.appendingPathComponent("sidecar", isDirectory: true))
            }
            candidates.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/audiorec/sidecar", isDirectory: true))

            for root in candidates {
                let python = root.appendingPathComponent(".venv/bin/python")
                let source = root.appendingPathComponent("src", isDirectory: true)
                if FileManager.default.isExecutableFile(atPath: python.path),
                   FileManager.default.fileExists(atPath: source.path) {
                    return Location(
                        python: python, sourceRoot: source,
                        workingDirectory: root.deletingLastPathComponent())
                }
            }
            return nil
        }
    }

    private let location: Location
    private var process: Process?
    private var stdinPipe: Pipe?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<SidecarResponse, Error>] = [:]
    /// 行の途中で読み込みが切れることがあるので、改行が来るまで貯める。
    private var buffer = Data()

    public init(location: Location) {
        self.location = location
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - 起動と終了

    public func start() throws {
        guard process == nil else { return }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        process.executableURL = location.python
        process.arguments = ["-m", "audiorec_asr"]
        process.currentDirectoryURL = location.workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        // サイドカーの進捗表示やライブラリの警告は stderr に出る。
        // 取り込むと NDJSON に混ざる危険があるので捨てる。
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = location.sourceRoot.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            throw SidecarError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdinPipe = stdin
    }

    public func stop() {
        guard let process else { return }
        // 応答待ちを宙吊りにしない
        failAllPending(SidecarError.terminated)
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        self.process = nil
        self.stdinPipe = nil
        buffer.removeAll()
    }

    private func handleTermination() {
        failAllPending(SidecarError.terminated)
        process = nil
        stdinPipe = nil
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - 呼び出し

    @discardableResult
    public func call(_ method: String, params: SidecarParams = SidecarParams()) async throws
        -> SidecarResponse
    {
        if process == nil { try start() }
        guard let stdinPipe else { throw SidecarError.notRunning }

        nextID += 1
        let id = nextID

        let request = SidecarRequest(id: id, method: method, params: params)
        let line: Data
        do {
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)  // 改行が 1 メッセージの区切り
            line = encoded
        } catch {
            throw SidecarError.encodingFailed(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: SidecarError.writeFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - 受信

    private func ingest(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            dispatch(lineData)
        }
    }

    private func dispatch(_ lineData: Data) {
        guard let response = try? JSONDecoder().decode(SidecarResponse.self, from: lineData) else {
            // プロトコルとして読めない行は捨てる。想定外の出力が
            // 混ざっても通信全体を壊さないようにするため。
            return
        }
        // 途中経過のイベントは今は使っていない。応答だけを拾う。
        guard response.event == nil, let continuation = pending.removeValue(forKey: response.id)
        else { return }
        continuation.resume(returning: response)
    }
}

// MARK: - メッセージ

public struct SidecarParams: Encodable, Sendable {
    public var path: String?
    public var model: String?
    public var language: String?
    public var initial_prompt: String?
    public var vad: Bool?

    public init(
        path: String? = nil, model: String? = nil, language: String? = nil,
        initial_prompt: String? = nil, vad: Bool? = nil
    ) {
        self.path = path
        self.model = model
        self.language = language
        self.initial_prompt = initial_prompt
        self.vad = vad
    }
}

struct SidecarRequest: Encodable {
    let id: Int
    let method: String
    let params: SidecarParams
}

public struct SidecarSegment: Decodable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let avg_logprob: Double?
    public let no_speech_prob: Double?
}

/// メソッドごとに result の形が違うため、まとめて省略可能にしてある。
public struct SidecarResult: Decodable, Sendable {
    public let text: String?
    public let segments: [SidecarSegment]?
    public let model: String?
    public let elapsed: Double?
    public let audio_duration: Double?
    public let speech_ratio: Double?
    public let ready: Bool?
    public let stopped: Bool?
}

public struct SidecarFailure: Decodable, Sendable {
    public let message: String
    public let kind: String?
}

public struct SidecarResponse: Decodable, Sendable {
    public let id: Int
    public let ok: Bool?
    public let event: String?
    public let result: SidecarResult?
    public let error: SidecarFailure?
}

public enum SidecarError: LocalizedError {
    case notInstalled
    case notRunning
    case launchFailed(String)
    case encodingFailed(String)
    case writeFailed(String)
    case terminated
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Whisper サイドカーが見つかりません。sidecar/.venv を作成してください。"
        case .notRunning:
            "サイドカーが起動していません"
        case .launchFailed(let detail):
            "サイドカーを起動できませんでした: \(detail)"
        case .encodingFailed(let detail):
            "リクエストを組み立てられませんでした: \(detail)"
        case .writeFailed(let detail):
            "サイドカーへ送信できませんでした: \(detail)"
        case .terminated:
            "サイドカーが終了しました"
        case .remote(let message):
            message
        }
    }
}
