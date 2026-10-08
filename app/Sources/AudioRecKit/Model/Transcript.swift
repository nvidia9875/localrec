import Foundation

/// 話者。2トラック録音の由来からラベル付けする。
public enum SpeakerRole: String, Codable, Sendable, CaseIterable {
    /// マイク入力 = このマシンの前にいる人
    case mySelf = "self"
    /// システム音声 = オンライン会議の相手
    case other
    /// 単一トラック録音などで判別できない場合
    case unknown

    public var displayName: String {
        switch self {
        case .mySelf: "自分"
        case .other: "相手"
        case .unknown: ""
        }
    }
}

/// 文字起こしの1発話。
public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// 録音開始からの秒数。2トラックでも共通のタイムライン上の値。
    public let start: TimeInterval
    public let end: TimeInterval
    public let speaker: SpeakerRole
    public let text: String
    /// エンジンが返した信頼度 (0...1)。低いものは UI で下線を引き修正を促す。
    public let confidence: Double?
    public let engine: ASREngineKind?
    /// 人が手で直したか。true のものは再転写で上書きしない。
    public let edited: Bool

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        speaker: SpeakerRole = .unknown,
        text: String,
        confidence: Double? = nil,
        engine: ASREngineKind? = nil,
        edited: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
        self.engine = engine
        self.edited = edited
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// 変更を加えた新しいインスタンスを返す (元は変更しない)。
    public func with(
        text: String? = nil,
        speaker: SpeakerRole? = nil,
        edited: Bool? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: start,
            end: end,
            speaker: speaker ?? self.speaker,
            text: text ?? self.text,
            confidence: confidence,
            engine: engine,
            edited: edited ?? self.edited
        )
    }

    /// 時刻を `offset` 秒ずらした新しいインスタンスを返す。
    /// 続きから録音したとき、エンジンが返す「その回の頭からの秒数」を
    /// 録音全体のタイムラインに載せ直すのに使う。
    public func shifted(by offset: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            start: start + offset,
            end: end + offset,
            speaker: speaker,
            text: text,
            confidence: confidence,
            engine: engine,
            edited: edited
        )
    }
}

/// 文字起こし全体。`transcript.json` として保存される正データ。
public struct Transcript: Codable, Sendable, Equatable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment] = []) {
        self.segments = segments
    }

    public static let empty = Transcript()

    public var isEmpty: Bool { segments.isEmpty }

    /// 全文をつないだテキスト。全文検索インデックスと CER 測定で使う。
    public var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// 開始時刻順に並べ直した新しい Transcript を返す。
    public func sorted() -> Transcript {
        Transcript(segments: segments.sorted { $0.start < $1.start })
    }

    /// セグメントを追加した新しい Transcript を返す。
    public func appending(_ segment: TranscriptSegment) -> Transcript {
        Transcript(segments: segments + [segment])
    }

    /// 指定 ID のセグメントを置き換えた新しい Transcript を返す。
    /// 該当が無ければ元と同じ内容を返す。
    public func replacing(id: UUID, with segment: TranscriptSegment) -> Transcript {
        Transcript(segments: segments.map { $0.id == id ? segment : $0 })
    }

    /// 指定時刻を含むセグメント。再生位置のハイライトに使う。
    public func segment(at time: TimeInterval) -> TranscriptSegment? {
        segments.first { time >= $0.start && time < $0.end }
    }
}
