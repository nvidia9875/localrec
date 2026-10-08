import Foundation

/// 要約レポートを表示するための、最小限の Markdown ブロック分解。
///
/// SwiftUI の `Text(.init(markdown:))` はインライン記法しか解釈せず、
/// 見出しも箇条書きも表も平文になってしまう。要約は見出しと表が主役なので、
/// ブロック単位に分けてから描画する。
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    /// 表。先頭行が見出し。
    case table(header: [String], rows: [[String]])
    case divider
}

public enum MarkdownBlocks {

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                index += 1
                continue
            }

            if isTableRow(trimmed) {
                flushParagraph()
                let (table, consumed) = parseTable(lines, from: index)
                if let table {
                    blocks.append(table)
                    index += consumed
                    continue
                }
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: - 個別の記法

    static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }

        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes, text: text)
    }

    static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count > 2
    }

    /// 区切り行（`|---|---|`）だけの表は、テンプレートの空欄なので表として扱わない。
    static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    static func splitRow(_ line: String) -> [String] {
        line
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 表を読み取り、消費した行数を返す。
    private static func parseTable(_ lines: [String], from start: Int) -> (MarkdownBlock?, Int) {
        var index = start
        var rows: [[String]] = []

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard isTableRow(trimmed) else { break }
            if !isSeparatorRow(trimmed) {
                rows.append(splitRow(trimmed))
            }
            index += 1
        }

        let consumed = index - start
        guard let header = rows.first else { return (nil, consumed) }

        // 中身が空の行は落とす。テンプレートの空欄をそのまま出さないため。
        let body = rows.dropFirst().filter { row in
            row.contains { !$0.isEmpty }
        }
        return (.table(header: header, rows: Array(body)), consumed)
    }
}
