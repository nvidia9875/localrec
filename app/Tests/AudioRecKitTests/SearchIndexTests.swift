import Foundation
import Testing

@testable import AudioRecKit

@Suite("録音を横断した全文検索")
struct SearchIndexTests {

    private func makeIndex() async -> SearchIndex {
        let index = SearchIndex()
        await index.update(
            recordingID: "rec-1", title: "設計レビュー",
            transcript: Transcript(segments: [
                TranscriptSegment(start: 0, end: 5, speaker: .mySelf, text: "2トラックに分ける設計です。"),
                TranscriptSegment(start: 5, end: 10, speaker: .other, text: "認識のずれが心配ですね。"),
                TranscriptSegment(start: 10, end: 15, speaker: .mySelf, text: "Kubernetes のリソースを見ます。"),
            ]))
        await index.update(
            recordingID: "rec-2", title: "朝会",
            transcript: Transcript(segments: [
                TranscriptSegment(start: 0, end: 4, speaker: .unknown, text: "今日の予定を共有します。")
            ]))
        return index
    }

    @Test("本文でヒットする")
    func findsByText() async {
        let hits = await makeIndex().search("設計")
        #expect(hits.count == 1)
        #expect(hits.first?.recordingID == "rec-1")
        #expect(hits.first?.start == 0)
    }

    @Test("カタカナとひらがなの違いを吸収する")
    func foldsKana() async {
        // 「ずれ」と「ズレ」は同じ語。書き分けで引けないのは実用上つらい。
        let index = await makeIndex()
        #expect(await index.search("ズレ").count == 1)
        #expect(await index.search("ずれ").count == 1)
    }

    @Test("全角半角と大小文字を吸収する")
    func normalizesWidthAndCase() async {
        let index = await makeIndex()
        #expect(await index.search("kubernetes").count == 1)
        #expect(await index.search("ＫＵＢＥＲＮＥＴＥＳ").count == 1)
    }

    @Test("句読点も検索できる")
    func keepsPunctuation() async {
        // 句読点を落とすと「です。」で文末を探せなくなる
        #expect(await makeIndex().search("です。").count == 1)
    }

    @Test("見つからなければ空を返す")
    func returnsEmptyWhenNoMatch() async {
        #expect(await makeIndex().search("存在しない語").isEmpty)
    }

    @Test("空の検索語では何も返さない")
    func ignoresEmptyQuery() async {
        let index = await makeIndex()
        #expect(await index.search("").isEmpty)
        #expect(await index.search("   ").isEmpty)
    }

    @Test("ヒットに話者と時刻が付く")
    func carriesSpeakerAndTime() async {
        let hit = await makeIndex().search("心配").first
        #expect(hit?.speaker == .other)
        #expect(hit?.start == 5)
        #expect(hit?.recordingTitle == "設計レビュー")
    }

    @Test("録音の絞り込みはタイトルも対象にする")
    func matchesTitlesToo() async {
        // 文字起こしが空の録音を探せなくなるため
        let ids = await makeIndex().recordingIDs(matching: "朝会")
        #expect(ids == ["rec-2"])
    }

    @Test("複数の録音にまたがってヒットする")
    func searchesAcrossRecordings() async {
        let index = await makeIndex()
        await index.update(
            recordingID: "rec-3", title: "定例",
            transcript: Transcript(segments: [
                TranscriptSegment(start: 0, end: 3, text: "設計を見直します。")
            ]))

        let ids = await index.recordingIDs(matching: "設計")
        #expect(ids == ["rec-1", "rec-3"])
    }

    @Test("同じ録音を更新すると古い内容は消える")
    func updateReplacesPreviousEntries() async {
        let index = await makeIndex()
        await index.update(
            recordingID: "rec-1", title: "設計レビュー",
            transcript: Transcript(segments: [
                TranscriptSegment(start: 0, end: 3, text: "全く別の内容。")
            ]))

        #expect(await index.search("2トラック").isEmpty)
        #expect(await index.search("全く別").count == 1)
    }

    @Test("改名すると新しい名前で絞り込める")
    func renameUpdatesTitleLookup() async {
        let index = await makeIndex()
        await index.rename("rec-1", to: "アーキテクチャ会")

        #expect(await index.recordingIDs(matching: "アーキテクチャ") == ["rec-1"])
        // 古い名前で引けたままだと、消したはずの名前が検索に残る
        #expect(await index.recordingIDs(matching: "設計レビュー").isEmpty)
    }

    @Test("改名しても発話の索引は残る")
    func renameKeepsSegments() async {
        let index = await makeIndex()
        await index.rename("rec-1", to: "アーキテクチャ会")

        #expect(await index.search("2トラック").count == 1)
    }

    @Test("改名は検索結果に出る録音名にも反映される")
    func renameUpdatesHitTitles() async {
        let index = await makeIndex()
        await index.rename("rec-1", to: "アーキテクチャ会")

        // 古い名前のまま出ると、どの録音の発話か分からなくなる
        #expect(await index.search("心配").first?.recordingTitle == "アーキテクチャ会")
    }

    @Test("削除すると引けなくなる")
    func removeDropsEntries() async {
        let index = await makeIndex()
        await index.remove(recordingID: "rec-1")

        #expect(await index.search("設計").isEmpty)
        #expect(await index.recordingIDs(matching: "設計レビュー").isEmpty)
    }

    @Test("件数の上限を守る")
    func respectsLimit() async {
        let index = SearchIndex()
        let segments = (0..<50).map {
            TranscriptSegment(start: TimeInterval($0), end: TimeInterval($0) + 1, text: "同じ語")
        }
        await index.update(
            recordingID: "many", title: "大量", transcript: Transcript(segments: segments))

        #expect(await index.search("同じ語", limit: 10).count == 10)
    }
}
