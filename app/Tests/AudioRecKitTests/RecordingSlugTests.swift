import Foundation
import Testing

@testable import AudioRecKit

@Suite("録音 ID (ディレクトリ名) の生成")
struct RecordingSlugTests {

    @Test("日付とタイトルから ID を組み立てる")
    func makesIDFromDateAndTitle() {
        let date = DateComponents(
            calendar: .current, timeZone: .current,
            year: 2026, month: 8, day: 11, hour: 14, minute: 12, second: 30
        ).date!

        #expect(RecordingSlug.make(date: date, title: "設計レビュー") == "2026-08-11_141230_設計レビュー")
    }

    @Test("パス区切りをディレクトリ名に混入させない")
    func replacesPathSeparators() {
        #expect(RecordingSlug.sanitize("a/b") == "a-b")
        #expect(RecordingSlug.sanitize("a:b") == "a-b")
        #expect(RecordingSlug.sanitize("a\\b") == "a-b")
    }

    @Test("制御文字を取り除く")
    func stripsControlCharacters() {
        #expect(RecordingSlug.sanitize("設計\u{0}レビュー") == "設計_レビュー")
        #expect(RecordingSlug.sanitize("設計\nレビュー") == "設計_レビュー")
        #expect(RecordingSlug.sanitize("設計\tレビュー") == "設計_レビュー")
    }

    @Test("空白の連続は 1 つのアンダースコアに畳む")
    func collapsesWhitespace() {
        #expect(RecordingSlug.sanitize("設計   レビュー") == "設計_レビュー")
        #expect(RecordingSlug.sanitize("  前後の空白  ") == "前後の空白")
        #expect(RecordingSlug.sanitize("全角　空白") == "全角_空白")
    }

    @Test("先頭のドットを落として不可視ファイル化を防ぐ")
    func stripsLeadingDots() {
        #expect(RecordingSlug.sanitize(".hidden") == "hidden")
        #expect(RecordingSlug.sanitize("...hidden") == "hidden")
    }

    @Test("末尾の区切り記号を落とす")
    func stripsTrailingPunctuation() {
        #expect(RecordingSlug.sanitize("会議...") == "会議")
        #expect(RecordingSlug.sanitize("会議___") == "会議")
        #expect(RecordingSlug.sanitize("会議---") == "会議")
    }

    @Test("実質空のタイトルは代替名にする")
    func fallsBackWhenEmpty() {
        #expect(RecordingSlug.sanitize("") == "無題")
        #expect(RecordingSlug.sanitize("   ") == "無題")
        #expect(RecordingSlug.sanitize("...") == "無題")
    }

    @Test("長いタイトルをバイト数上限で切り詰める")
    func truncatesLongTitles() {
        // 日本語は 1 文字 3 バイト。100 文字 = 300 バイトで上限を超える。
        let long = String(repeating: "あ", count: 100)
        let result = RecordingSlug.sanitize(long)

        #expect(result.utf8.count <= RecordingSlug.maxTitleBytes)
        #expect(result.count == RecordingSlug.maxTitleBytes / 3)
    }

    @Test("切り詰めで文字を壊さない")
    func truncationDoesNotSplitCharacters() {
        // 絵文字 (サロゲートペア) と結合文字が途中で割れないこと
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 20)
        let result = RecordingSlug.truncateToBytes(emoji, limit: 30)

        #expect(result.utf8.count <= 30)
        // 復元して比較できる = 不正なバイト列になっていない
        #expect(String(data: Data(result.utf8), encoding: .utf8) == result)
    }

    @Test("上限以下の文字列はそのまま返す")
    func doesNotTruncateShortStrings() {
        #expect(RecordingSlug.truncateToBytes("短い", limit: 100) == "短い")
    }

    @Test("ID の衝突を連番で回避する")
    func deduplicatesCollidingIDs() {
        #expect(RecordingSlug.deduplicated("a", existing: []) == "a")
        #expect(RecordingSlug.deduplicated("a", existing: ["a"]) == "a-2")
        #expect(RecordingSlug.deduplicated("a", existing: ["a", "a-2"]) == "a-3")
        #expect(RecordingSlug.deduplicated("a", existing: ["b"]) == "a")
    }
}
