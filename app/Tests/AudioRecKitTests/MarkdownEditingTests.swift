import Foundation
import Testing

@testable import AudioRecKit

@Suite("メモ入力の Markdown 補助")
struct MarkdownEditingTests {

    // MARK: - 箇条書きの継続

    @Test("箇条書きの次の行の記号を決める")
    func continuesBullet() throws {
        let item = try #require(MarkdownList.item(in: "- 予算は未確定"))
        #expect(item.indent == "")
        #expect(item.nextPrefix == "- ")
        #expect(item.prefixLength == 2)
        #expect(!item.isEmpty)
    }

    @Test("字下げを引き継ぐ")
    func keepsIndent() throws {
        let item = try #require(MarkdownList.item(in: "    * 小項目"))
        #expect(item.nextPrefix == "    * ")
        #expect(item.prefixLength == 6)
    }

    @Test("番号付きは次の番号にする")
    func incrementsNumber() throws {
        let item = try #require(MarkdownList.item(in: "9. 九つ目"))
        #expect(item.nextPrefix == "10. ")
        #expect(item.prefixLength == 3)
    }

    @Test("チェックボックスは未完了で続ける")
    func continuesCheckboxUnchecked() throws {
        let item = try #require(MarkdownList.item(in: "- [x] 終わった宿題"))
        #expect(item.nextPrefix == "- [ ] ")
        #expect(item.prefixLength == 6)
    }

    @Test("記号だけの行は空の項目として扱う")
    func detectsEmptyItem() throws {
        #expect(try #require(MarkdownList.item(in: "- ")).isEmpty)
        #expect(try #require(MarkdownList.item(in: "2. ")).isEmpty)
        #expect(try #require(MarkdownList.item(in: "- [ ] ")).isEmpty)
        #expect(try #require(MarkdownList.item(in: "- [ ]")).isEmpty)
    }

    @Test("箇条書きでない行は対象外", arguments: ["普通の文", "-ハイフンだけ", "---", "# 見出し", ""])
    func ignoresNonListLine(line: String) {
        #expect(MarkdownList.item(in: line) == nil)
    }

    // MARK: - 記法の色分け

    @Test("見出しは記号と本文に分ける")
    func spansHeading() {
        let spans = MarkdownSyntax.spans(in: "## 決定事項")
        #expect(spans.contains(.init(kind: .heading(level: 2), range: NSRange(location: 0, length: 7))))
        #expect(spans.contains(.init(kind: .marker, range: NSRange(location: 0, length: 3))))
    }

    @Test("太字の記号は薄く、中身は太く")
    func spansStrong() {
        let spans = MarkdownSyntax.spans(in: "これは**大事**です")
        #expect(spans.contains(.init(kind: .strong, range: NSRange(location: 3, length: 6))))
        #expect(spans.contains(.init(kind: .marker, range: NSRange(location: 3, length: 2))))
        #expect(spans.contains(.init(kind: .marker, range: NSRange(location: 7, length: 2))))
    }

    @Test("インラインコード")
    func spansCode() {
        let spans = MarkdownSyntax.spans(in: "`make bench` で再現")
        #expect(spans.contains(.init(kind: .code, range: NSRange(location: 0, length: 12))))
    }

    @Test("完了したチェックボックスの本文は完了扱い")
    func spansCheckedTask() {
        let spans = MarkdownSyntax.spans(in: "- [x] 送付済み")
        #expect(spans.contains(.init(kind: .marker, range: NSRange(location: 0, length: 6))))
        #expect(spans.contains(.init(kind: .checked, range: NSRange(location: 6, length: 4))))
    }

    @Test("2行目以降も行頭として読む")
    func spansMultiline() {
        let spans = MarkdownSyntax.spans(in: "メモ\n# 宿題\n> 引用")
        #expect(spans.contains(.init(kind: .heading(level: 1), range: NSRange(location: 3, length: 4))))
        #expect(spans.contains(.init(kind: .quote, range: NSRange(location: 10, length: 2))))
        #expect(spans.contains(.init(kind: .marker, range: NSRange(location: 8, length: 2))))
    }

    @Test("記法の無い文は何も返さない")
    func plainTextHasNoSpans() {
        #expect(MarkdownSyntax.spans(in: "ただの文章です。").isEmpty)
    }
}
