import Foundation

public enum RecordingStoreError: LocalizedError, Equatable {
    case notFound(id: String)
    case corruptMetadata(id: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            "録音が見つかりません: \(id)"
        case .corruptMetadata(let id, let underlying):
            "メタデータを読めませんでした (\(id)): \(underlying)"
        }
    }
}

/// 録音の保存・読み出しを担う。ファイルシステムが唯一の真実の源。
///
/// I/O を UI スレッドから追い出すため actor にしている。
public actor RecordingStore {
    /// パス計算は不変な値の組み立てでしかないので、actor の外から同期的に読めるようにする。
    /// これが await 必須だと、UI がファイル URL を組み立てるだけで非同期になってしまう。
    public nonisolated let paths: StoragePaths
    private let fileManager: FileManager

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // 人間と Claude が直接読めることを優先する
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(paths: StoragePaths = StoragePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    // MARK: - 作成

    /// 新しい録音ディレクトリを作り、メタデータを書き込む。
    /// ID が既存と衝突する場合は連番を付けて回避する。
    @discardableResult
    public func create(title: String, at date: Date = Date()) throws -> RecordingMeta {
        let base = RecordingSlug.make(date: date, title: title)
        let id = RecordingSlug.deduplicated(base, existing: Set(try existingIDs()))
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let meta = RecordingMeta(
            id: id,
            title: displayTitle.isEmpty ? RecordingSlug.fallbackTitle : displayTitle,
            createdAt: date
        )

        try fileManager.createDirectory(
            at: paths.audioDirectory(id), withIntermediateDirectories: true)
        try saveMeta(meta)
        try saveTranscript(.empty, for: id)
        return meta
    }

    // MARK: - 一覧・読み出し

    /// 録音一覧を新しい順で返す。
    /// 壊れた録音は一覧から静かに落とさず、読める分だけ返した上で件数の差が分かるようにする。
    public func list() throws -> [RecordingMeta] {
        try existingIDs()
            .compactMap { try? loadMeta($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func loadMeta(_ id: String) throws -> RecordingMeta {
        let url = paths.metaFile(id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RecordingStoreError.notFound(id: id)
        }
        do {
            return try decoder.decode(RecordingMeta.self, from: try Data(contentsOf: url))
        } catch {
            throw RecordingStoreError.corruptMetadata(
                id: id, underlying: error.localizedDescription)
        }
    }

    /// 文字起こしを読む。まだ無い / 壊れている場合は空を返す。
    /// 音声さえ残っていれば再転写できるので、ここで例外にして録音全体を
    /// 開けなくするより空で開ける方が実害が小さい。
    public func loadTranscript(_ id: String) -> Transcript {
        let url = paths.transcriptFile(id)
        guard let data = try? Data(contentsOf: url),
              let t = try? decoder.decode(Transcript.self, from: data)
        else { return .empty }
        return t
    }

    public func load(_ id: String) throws -> Recording {
        Recording(meta: try loadMeta(id), transcript: loadTranscript(id))
    }

    // MARK: - 保存

    public func saveMeta(_ meta: RecordingMeta) throws {
        try fileManager.createDirectory(
            at: paths.recordingDirectory(meta.id), withIntermediateDirectories: true)
        try encoder.encode(meta).write(to: paths.metaFile(meta.id), options: .atomic)
    }

    /// 文字起こしを保存する。`transcript.json` が正データで、
    /// `.md` と `.srt` はそこから毎回作り直す派生物。
    public func saveTranscript(_ transcript: Transcript, for id: String) throws {
        let sorted = transcript.sorted()
        try fileManager.createDirectory(
            at: paths.recordingDirectory(id), withIntermediateDirectories: true)
        try encoder.encode(sorted).write(to: paths.transcriptFile(id), options: .atomic)

        let meta = try? loadMeta(id)
        let markdown = TranscriptFormatter.markdown(sorted, meta: meta)
        try Data(markdown.utf8).write(to: paths.transcriptMarkdownFile(id), options: .atomic)

        let srt = TranscriptFormatter.srt(sorted)
        try Data(srt.utf8).write(to: paths.transcriptSRTFile(id), options: .atomic)
    }

    public func saveSummary(_ markdown: String, for id: String) throws {
        try fileManager.createDirectory(
            at: paths.recordingDirectory(id), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: paths.summaryFile(id), options: .atomic)
    }

    public func loadSummary(_ id: String) -> String? {
        try? String(contentsOf: paths.summaryFile(id), encoding: .utf8)
    }

    /// 要約を消す。「作り直す」は「消してから作る」なので、
    /// 生成に失敗したときに古い要約が残って新旧が混ざらないようにする。
    public func deleteSummary(_ id: String) throws {
        let url = paths.summaryFile(id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// メモを保存する。空なら書かずに消す (空ファイルを残さない)。
    public func saveMemo(_ text: String, for id: String) throws {
        let url = paths.memoFile(id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        try fileManager.createDirectory(
            at: paths.recordingDirectory(id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// メモを読む。無ければ空文字。メモが無いことは異常ではない。
    public func loadMemo(_ id: String) -> String {
        (try? String(contentsOf: paths.memoFile(id), encoding: .utf8)) ?? ""
    }

    // MARK: - 変更

    /// タイトルを変更する。ディレクトリ名 (= ID) は変えない。
    /// ID を変えると音声ファイルへの参照や検索インデックスが一斉に壊れるため、
    /// 表示名だけを差し替える方が安全。
    @discardableResult
    public func rename(_ id: String, to title: String) throws -> RecordingMeta {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try loadMeta(id).with(
            title: trimmed.isEmpty ? RecordingSlug.fallbackTitle : trimmed)
        try saveMeta(updated)
        return updated
    }

    /// 登場人物を差し替える。空白除去と重複排除は `RecordingMeta` 側で行う。
    @discardableResult
    public func setParticipants(_ participants: [String], for id: String) throws -> RecordingMeta {
        let updated = try loadMeta(id).with(participants: participants)
        try saveMeta(updated)
        return updated
    }

    public func delete(_ id: String) throws {
        let dir = paths.recordingDirectory(id)
        guard fileManager.fileExists(atPath: dir.path) else {
            throw RecordingStoreError.notFound(id: id)
        }
        try fileManager.removeItem(at: dir)
    }

    /// ASR 入力用の WAV を削除して容量を空ける。m4a と文字起こしは残る。
    public func purgeASRAudio(_ id: String) throws {
        for track in TrackKind.allCases {
            let url = paths.asrAudioFile(id, track: track)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - 内部

    /// ルート直下の、meta.json を持つディレクトリ名を列挙する。
    private func existingIDs() throws -> [String] {
        guard fileManager.fileExists(atPath: paths.root.path) else {
            try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            return []
        }
        let entries = try fileManager.contentsOfDirectory(
            at: paths.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries.filter { url in
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else { return false }
            return fileManager.fileExists(atPath: url.appendingPathComponent("meta.json").path)
        }.map(\.lastPathComponent)
    }
}
