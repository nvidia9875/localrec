import Foundation

/// `claude -p` を呼ぶ口。テストでは差し替える。
public protocol ClaudeRunner: Sendable {
    /// プロンプトと標準入力を渡し、応答テキストを返す。
    func run(prompt: String, input: String) async throws -> String
}

public enum ClaudeCLIError: LocalizedError {
    case notInstalled
    case launchFailed(String)
    case timedOut(TimeInterval)
    case failed(exitCode: Int32, message: String)
    case unreadableResponse(String)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            """
            claude コマンドが見つかりません。
            Claude Code をインストールするか、環境変数 AUDIOREC_CLAUDE_PATH で場所を指定してください。
            """
        case .launchFailed(let detail):
            "claude を起動できませんでした: \(detail)"
        case .timedOut(let seconds):
            "claude の応答が \(Int(seconds)) 秒以内に返りませんでした"
        case .failed(let code, let message):
            "claude が失敗しました (終了コード \(code)): \(message)"
        case .unreadableResponse(let detail):
            "claude の応答を解釈できませんでした: \(detail)"
        case .remote(let message):
            "claude がエラーを返しました: \(message)"
        }
    }
}

/// `claude -p` をサブプロセスとして呼ぶ。
///
/// 文字起こしの整形と要約に使う。ローカルの ASR とは独立した後処理なので、
/// ここが失敗しても文字起こし自体は残る。失敗は必ず呼び出し元に伝える。
public struct ClaudeCLI: ClaudeRunner {

    public struct Configuration: Sendable {
        public var executable: URL
        public var model: String
        /// 待ち時間の下限。実際にはここに入力の長さ分を足す。
        public var timeout: TimeInterval
        /// 思考の深さ。整形も要約も「決まった型に流し込む」作業で、
        /// 深く考えるほど良くなる仕事ではない。既定を継ぐと
        /// 応答の大半が思考トークンになり、待ち時間だけが伸びる。
        public var effort: String

        public init(
            executable: URL, model: String = "sonnet", timeout: TimeInterval = 180,
            effort: String = "low"
        ) {
            self.executable = executable
            self.model = model
            self.timeout = timeout
            self.effort = effort
        }
    }

    /// 入力 1000 文字あたりに足す待ち時間。
    /// 40 分の会議で 3 万字を超える。固定値だと長い会議ほど確実に落ちる。
    static let secondsPerThousandCharacters: TimeInterval = 6

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// 実行ファイルを探す。見つからなければ nil。
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["AUDIOREC_CLAUDE_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/claude"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func make(
        model: String = "sonnet", timeout: TimeInterval = 180, effort: String = "low"
    ) throws -> ClaudeCLI {
        guard let executable = discover() else { throw ClaudeCLIError.notInstalled }
        return ClaudeCLI(
            configuration: Configuration(
                executable: executable, model: model, timeout: timeout, effort: effort))
    }

    // MARK: - 実行

    public func run(prompt: String, input: String) async throws -> String {
        let output = try await execute(prompt: prompt, input: input)
        return try Self.extractResult(from: output)
    }

    private func execute(prompt: String, input: String) async throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = configuration.executable
        process.arguments = Self.arguments(prompt: prompt, configuration: configuration)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // 作業ディレクトリの CLAUDE.md を読ませない。
        // プロジェクト固有の指示が整形結果に影響するのを避ける。
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        do {
            try process.run()
        } catch {
            throw ClaudeCLIError.launchFailed(error.localizedDescription)
        }

        // 入力は別スレッドから流し込む。
        // パイプの緩衝は 64KB しかなく、40 分の会議の文字起こしは
        // 平気でそれを超える。ここで同期に書くと claude が読み進めるまで
        // 戻らず、下の時間切れの見張りにすら入れない。UI は「生成中」の
        // まま永久に戻らなくなる。
        let payload = Data(input.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(payload)
            // 閉じないと claude は入力待ちのまま止まる。
            try? stdin.fileHandleForWriting.close()
        }

        // stderr も並行して読み切る。放っておくとこちらのパイプが詰まり、
        // claude が書き込みでブロックして応答が返らなくなる。
        let errorOutput = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            errorOutput.set(stderr.fileHandleForReading.readDataToEndOfFile())
        }

        let outputData = try await withDeadline(
            Self.deadline(for: input, configuration: configuration), process: process
        ) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClaudeCLIError.failed(
                exitCode: process.terminationStatus,
                message: errorOutput.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outputData
    }

    static func arguments(prompt: String, configuration: Configuration) -> [String] {
        [
            "-p", prompt,
            "--output-format", "json",
            "--model", configuration.model,
            // 型に流し込むだけの仕事なので、深く考えさせない。
            "--effort", configuration.effort,
            // 後処理は 1 回きりの変換。履歴を残す必要がない。
            "--no-session-persistence",
            // 使い手が入れている MCP サーバーを起動しない。
            // 後処理に要らないうえ、接続を待つ分だけ返りが遅くなる。
            "--strict-mcp-config",
            // 使い手個人の設定 (CLAUDE.md・プラグイン・スキル・思考の既定) を読まない。
            // 後処理の結果が使い手の設定で変わってはいけないし、
            // 実測ではこれだけでプロンプトが 3 万トークン以上膨らんでいた。
            "--setting-sources", "",
        ]
    }

    /// 実際に待つ時間。入力が長いほど生成にも時間がかかる。
    static func deadline(for input: String, configuration: Configuration) -> TimeInterval {
        configuration.timeout
            + Double(input.count) / 1000 * secondsPerThousandCharacters
    }

    /// 応答を待つ間に時間切れを見張る。
    /// 待ち続けると UI が「要約中」のまま永久に戻らなくなる。
    private func withDeadline(
        _ seconds: TimeInterval, process: Process, work: @escaping @Sendable () -> Data
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: work())
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }

            defer { group.cancelAll() }
            for try await result in group {
                if let result { return result }
                if process.isRunning { process.terminate() }
                throw ClaudeCLIError.timedOut(seconds)
            }
            throw ClaudeCLIError.timedOut(seconds)
        }
    }

    /// `--output-format json` の封筒から本文を取り出す。
    static func extractResult(from data: Data) throws -> String {
        struct Envelope: Decodable {
            let result: String?
            let is_error: Bool?
            let error: String?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "(読めません)"
            throw ClaudeCLIError.unreadableResponse(preview)
        }
        if envelope.is_error == true {
            throw ClaudeCLIError.remote(envelope.error ?? envelope.result ?? "詳細不明")
        }
        guard let result = envelope.result else {
            throw ClaudeCLIError.unreadableResponse("result が空です")
        }
        return result
    }
}

/// 別スレッドで読んだ出力を受け渡す入れもの。
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
