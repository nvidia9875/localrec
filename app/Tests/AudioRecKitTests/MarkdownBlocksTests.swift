import Foundation
import Testing

@testable import AudioRecKit

@Suite("要約 Markdown のブロック分解")
struct MarkdownBlocksTests {

    @Test("見出しの階層を読む")
    func parsesHeadings() {
        #expect(MarkdownBlocks.parse("# 見出し") == [.heading(level: 1, text: "見出し")])
        #expect(MarkdownBlocks.parse("### 小見出し") == [.heading(level: 3, text: "小見出し")])
    }

    @Test("# だけの行は見出しにしない")
    func ignoresEmptyHeading() {
        #expect(MarkdownBlocks.parse("#") == [.paragraph("#")])
    }

    @Test("箇条書きを読む")
    func parsesBullets() {
        let blocks = MarkdownBlocks.parse("- 一つ目\n- 二つ目")
        #expect(blocks == [.bullet("一つ目"), .bullet("二つ目")])
    }

    @Test("段落は連続行をまとめる")
    func joinsParagraphLines() {
        let blocks = MarkdownBlocks.parse("これは\n段落です\n\n次の段落")
        #expect(blocks == [.paragraph("これは 段落です"), .paragraph("次の段落")])
    }

    @Test("表を見出しと本文に分ける")
    func parsesTable() {
        let markdown = """
            | 内容 | 担当 | 期限 |
            |---|---|---|
            | 設計を見直す | 鴻上 | 8/20 |
            """
        #expect(
            MarkdownBlocks.parse(markdown)
                == [.table(header: ["内容", "担当", "期限"], rows: [["設計を見直す", "鴻上", "8/20"]])])
    }

    @Test("区切り行は表の内容に含めない")
    func skipsSeparatorRow() {
        // `|---|---|` を行として出すと表に空の行が混ざる
        #expect(MarkdownBlocks.isSeparatorRow("|---|---|"))
        #expect(MarkdownBlocks.isSeparatorRow("| :--- | ---: |"))
        #expect(!MarkdownBlocks.isSeparatorRow("| 内容 | 担当 |"))
    }

    @Test("空欄だけの行は落とす")
    func dropsEmptyTableRows() {
        // テンプレートの空欄がそのまま表示されるのを避ける
        let markdown = """
            | 内容 | 担当 |
            |---|---|
            | | |
            """
        #expect(MarkdownBlocks.parse(markdown) == [.table(header: ["内容", "担当"], rows: [])])
    }

    @Test("水平線を読む")
    func parsesDivider() {
        #expect(MarkdownBlocks.parse("---") == [.divider])
    }

    @Test("空文字は空の結果になる")
    func handlesEmptyInput() {
        #expect(MarkdownBlocks.parse("").isEmpty)
        #expect(MarkdownBlocks.parse("\n\n\n").isEmpty)
    }

    @Test("要約レポート全体を分解できる")
    func parsesFullReport() {
        let markdown = """
            # 設計レビュー 要約レポート

            - 実施日: 2026-08-11

            ## 会議概要

            2 トラック録音の設計について議論した。

            ## アクションアイテム

            | 内容 | 担当 | 期限 |
            |---|---|---|
            | 設計を見直す | 鴻上 | 8/20 |
            """
        let blocks = MarkdownBlocks.parse(markdown)

        #expect(blocks.count == 6)
        #expect(blocks.first == .heading(level: 1, text: "設計レビュー 要約レポート"))
        if case .table(let header, let rows) = blocks.last {
            #expect(header == ["内容", "担当", "期限"])
            #expect(rows.count == 1)
        } else {
            Issue.record("最後のブロックが表ではありません: \(String(describing: blocks.last))")
        }
    }
}
