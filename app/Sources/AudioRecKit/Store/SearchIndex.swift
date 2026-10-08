import Foundation

/// 検索でヒットした発話。
public struct SearchHit: Sendable, Equatable, Identifiable {
    public let recordingID: String
    public let recordingTitle: String
    public let segmentID: UUID
    public let start: TimeInterval
    public let speaker: SpeakerRole
    /// マッチした発話の本文。セグメントは 1 文程度なのでそのまま出せる。
    public let text: String

    public var id: String { "\(recordingID)#\(segmentID.uuidString)" }

    public init(
        recordingID: String, recordingTitle: String, segmentID: UUID,
        start: TimeInterval, speaker: SpeakerRole, text: String
    ) {
        self.recordingID = recordingID
        self.recordingTitle = recordingTitle
        self.segmentID = segmentID
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// 録音を横断して文字起こしを検索する。
///
/// SQLite の FTS5 を使わない理由: 既定のトークナイザは空白で語を切るため、
/// 語境界の無い日本語ではほとんど機能しない。trigram や ICU に切り替える手も
/// あるが、個人利用の規模（数百件）なら全文をメモリに持って正規化つきで
/// 探す方が、単純で、日本語に対しては素直に正しい。
///
/// 正規化を通すので「ずれ」「ズレ」「ｽﾞﾚ」「Kubernetes」「kubernetes」が
/// 同じ語として引ける。
public actor SearchIndex {

    private struct Entry {
        let recordingID: String
        let recordingTitle: String
        let segmentID: UUID
        let start: TimeInterval
        let speaker: SpeakerRole
        let text: String
        /// 比較用に正規化した本文
        let normalized: String

        func with(title: String) -> Entry {
            Entry(
                recordingID: recordingID, recordingTitle: title, segmentID: segmentID,
                start: start, speaker: speaker, text: text, normalized: normalized)
        }
    }

    private var entries: [Entry] = []
    private var indexedTitles: [String: String] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// 全録音を読み直してインデックスを作る。
    ///
    /// ファイルが真実の源なので、インデックスはいつでも捨てて作り直せる。
    /// 壊れる心配をしなくてよいのが、この方式のもう 1 つの利点。
    public func rebuild(from store: RecordingStore) async {
        var built: [Entry] = []
        var titles: [String: String] = [:]

        let metas = (try? await store.list()) ?? []
        for meta in metas {
            titles[meta.id] = meta.title
            let transcript = await store.loadTranscript(meta.id)
            for segment in transcript.segments {
                built.append(
                    Entry(
                        recordingID: meta.id,
                        recordingTitle: meta.title,
                        segmentID: segment.id,
                        start: segment.start,
                        speaker: segment.speaker,
                        text: segment.text,
                        normalized: Self.normalize(segment.text)))
            }
        }

        entries = built
        indexedTitles = titles
    }

    /// 1 件ぶんだけ入れ替える。録音の直後や整形後に全件読み直さないための入口。
    public func update(recordingID: String, title: String, transcript: Transcript) {
        entries.removeAll { $0.recordingID == recordingID }
        indexedTitles[recordingID] = title

        for segment in transcript.segments {
            entries.append(
                Entry(
                    recordingID: recordingID,
                    recordingTitle: title,
                    segmentID: segment.id,
                    start: segment.start,
                    speaker: segment.speaker,
                    text: segment.text,
                    normalized: Self.normalize(segment.text)))
        }
    }

    /// 表示名だけを差し替える。
    ///
    /// 発話は何も変わらないので、文字起こしを読み直す必要はない。
    /// これを呼ばないと、改名した名前では絞り込めず、
    /// 検索結果にも古い名前が出たままになる。
    public func rename(_ recordingID: String, to title: String) {
        guard indexedTitles[recordingID] != nil else { return }
        indexedTitles[recordingID] = title

        for index in entries.indices where entries[index].recordingID == recordingID {
            entries[index] = entries[index].with(title: title)
        }
    }

    public func remove(recordingID: String) {
        entries.removeAll { $0.recordingID == recordingID }
        indexedTitles[recordingID] = nil
    }

    // MARK: - 検索

    /// 発話を検索する。古い録音より新しい録音を優先はせず、時刻順に返す。
    public func search(_ query: String, limit: Int = 100) -> [SearchHit] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }

        return entries
            .filter { $0.normalized.contains(needle) }
            .prefix(limit)
            .map {
                SearchHit(
                    recordingID: $0.recordingID,
                    recordingTitle: $0.recordingTitle,
                    segmentID: $0.segmentID,
                    start: $0.start,
                    speaker: $0.speaker,
                    text: $0.text)
            }
    }

    /// 検索語を含む録音の ID。サイドバーの絞り込みに使う。
    public func recordingIDs(matching query: String) -> Set<String> {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }

        var matched = Set<String>()
        // タイトルも対象にする。文字起こしが空の録音を探せなくなるため。
        for (id, title) in indexedTitles where Self.normalize(title).contains(needle) {
            matched.insert(id)
        }
        for entry in entries where entry.normalized.contains(needle) {
            matched.insert(entry.recordingID)
        }
        return matched
    }

    /// 検索用の正規化。
    /// 句読点は落とさない。「はい。」で探したときに文末だけを引けなくなるため。
    static func normalize(_ text: String) -> String {
        JapaneseText.normalizeForComparison(
            text, removePunctuation: false, normalizeNumbers: false, foldKana: true)
    }
}
