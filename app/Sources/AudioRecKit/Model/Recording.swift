import Foundation

/// 録音トラックの種別。マイクとシステム音声を別トラックで保持することが
/// そのまま話者分離になる (マイク=自分 / システム=相手)。
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case mic
    case system
}

/// 文字起こしエンジンの種別。
public enum ASREngineKind: String, Codable, Sendable, CaseIterable {
    /// Apple の SpeechAnalyzer (macOS 26+)。完全オンデバイス、ローカル LLM 不要。
    case apple
    /// mlx-whisper サイドカー。ローカル LLM (Whisper 系モデル) を使う。
    case mlx

    public var displayName: String {
        switch self {
        case .apple: "Apple 音声認識"
        case .mlx: "Whisper (MLX)"
        }
    }
}

/// 録音1件のメタデータ。`meta.json` として録音ディレクトリ直下に保存される。
public struct RecordingMeta: Codable, Sendable, Equatable, Identifiable {
    /// スキーマを変えたときに古いファイルを判別するための版番号。
    public static let currentSchemaVersion = 1

    /// 録音ディレクトリ名がそのまま ID。例: `2026-08-11_141230_設計レビュー`
    public let id: String
    public let title: String
    public let createdAt: Date
    public let duration: TimeInterval
    public let tracks: [TrackKind]
    public let engine: ASREngineKind?
    public let model: String?
    /// 登場人物の名前。人が手で入れる。
    /// 誤変換されやすい人名の正解表記なので、整形と要約のヒントに渡す。
    public let participants: [String]
    public let schemaVersion: Int

    public init(
        id: String,
        title: String,
        createdAt: Date,
        duration: TimeInterval = 0,
        tracks: [TrackKind] = [.mic],
        engine: ASREngineKind? = nil,
        model: String? = nil,
        participants: [String] = [],
        schemaVersion: Int = RecordingMeta.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.tracks = tracks
        self.engine = engine
        self.model = model
        self.participants = RecordingMeta.normalized(participants)
        self.schemaVersion = schemaVersion
    }

    /// 項目を後から足しても既存の `meta.json` が読めるようにする。
    /// ここを合成のままにすると、`participants` の無い古いファイルが
    /// 全て `corruptMetadata` になって録音が一覧から消える。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        tracks = try container.decodeIfPresent([TrackKind].self, forKey: .tracks) ?? [.mic]
        engine = try container.decodeIfPresent(ASREngineKind.self, forKey: .engine)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        participants = RecordingMeta.normalized(
            try container.decodeIfPresent([String].self, forKey: .participants) ?? [])
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? RecordingMeta.currentSchemaVersion
    }

    /// 前後の空白を落とし、空文字と重複を取り除く。順序は入力のまま。
    static func normalized(_ participants: [String]) -> [String] {
        var seen = Set<String>()
        return participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 変更を加えた新しいインスタンスを返す (元は変更しない)。
    public func with(
        title: String? = nil,
        duration: TimeInterval? = nil,
        tracks: [TrackKind]? = nil,
        engine: ASREngineKind? = nil,
        model: String? = nil,
        participants: [String]? = nil
    ) -> RecordingMeta {
        RecordingMeta(
            id: id,
            title: title ?? self.title,
            createdAt: createdAt,
            duration: duration ?? self.duration,
            tracks: tracks ?? self.tracks,
            engine: engine ?? self.engine,
            model: model ?? self.model,
            participants: participants ?? self.participants,
            schemaVersion: schemaVersion
        )
    }
}

/// メタデータと文字起こしを束ねた、UI が扱う単位。
public struct Recording: Sendable, Equatable, Identifiable {
    public let meta: RecordingMeta
    public let transcript: Transcript

    public var id: String { meta.id }

    public init(meta: RecordingMeta, transcript: Transcript) {
        self.meta = meta
        self.transcript = transcript
    }
}
