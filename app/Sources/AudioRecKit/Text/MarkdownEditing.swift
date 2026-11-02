import Foundation

// メモ欄で Markdown を書くための補助。
//
// 描画（フォント・色）は AppKit 側に任せ、ここでは「どこが何の記法か」と
// 「改行したとき次の行に何を出すか」だけを決める。範囲はすべて UTF-16 単位の
// `NSRange` で返す。NSTextStorage にそのまま当てるため。

// MARK: - 箇条書きの継続

/// 箇条書き・番号付き・チェックボックスの 1 行。
public struct MarkdownListItem: Sendable, Equatable {
    /// 行頭の字下げ
    public let indent: String
    /// 字下げ＋記号の長さ（UTF-16）。カーソルがこれより前なら継続しない。
    public let prefixLength: Int
    /// 改行したときに次の行の頭に入れる文字列（字下げ込み）
    public let nextPrefix: String
    /// 記号だけで本文が無い。ここで改行したら箇条書きを抜ける。
    public let isEmpty: Bool
}

public enum MarkdownList {

    private static let pattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))[ \t]+(\[[ xX]\](?:[ \t]+|$))?(.*)$"#)

    public static func item(in line: String) -> MarkdownListItem? {
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        let indent = group(1) ?? ""
        let checkbox = group(5) == nil ? "" : "[ ] "
        let marker: String
        if let bullet = group(2) {
            marker = bullet + " "
        } else if let number = group(3).flatMap(Int.init), let delimiter = group(4) {
            marker = "\(number + 1)\(delimiter) "
        } else {
            return nil
        }

        let content = group(6) ?? ""
        return MarkdownListItem(
            indent: indent,
            prefixLength: match.range(at: 6).location,
            nextPrefix: indent + marker + checkbox,
            isEmpty: content.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }
}

// MARK: - 記法の色分け

public enum MarkdownSyntaxKind: Sendable, Equatable {
    /// 見出しの行全体（記号を含む）
    case heading(level: Int)
    /// 薄く見せる記号（`#`、`-`、`**`、`` ` `` など）
    case marker
    case strong
    case code
    case quote
    /// 完了したチェックボックスの本文
    case checked
}

public struct MarkdownSyntaxSpan: Sendable, Equatable {
    public let kind: MarkdownSyntaxKind
    public let range: NSRange

    public init(kind: MarkdownSyntaxKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum MarkdownSyntax {

    private static let heading = regex(#"^(#{1,6}[ \t]+)(.*)$"#)
    private static let list = regex(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[([ xX])\](?:[ \t]+|$))?"#)
    private static let quote = regex(#"^([ \t]*>[ \t]?)(.*)$"#)
    private static let rule = regex(#"^[ \t]*(?:-{3,}|\*{3,})[ \t]*$"#)
    private static let strong = regex(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#)
    private static let code = regex(#"(`)([^`\n]+)(`)"#)

    /// 描画側はこの順に当てる。後の span ほど優先される（記号の薄色を最後に被せる）。
    public static func spans(in text: String) -> [MarkdownSyntaxSpan] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [MarkdownSyntaxSpan] = []
        var markers: [NSRange] = []

        for match in heading.matches(in: text, range: whole) {
            let marker = match.range(at: 1)
            let level = ns.substring(with: marker).filter { $0 == "#" }.count
            spans.append(.init(kind: .heading(level: level), range: match.range))
            markers.append(marker)
        }
        for match in quote.matches(in: text, range: whole) {
            spans.append(.init(kind: .quote, range: match.range(at: 2)))
            markers.append(match.range(at: 1))
        }
        for match in list.matches(in: text, range: whole) {
            markers.append(match.range)
            let box = match.range(at: 1)
            guard box.location != NSNotFound, ns.substring(with: box) != " " else { continue }
            let lineEnd = ns.lineRange(for: match.range).upperBound
            let contentEnd = lineEnd > match.range.upperBound && ns.character(at: lineEnd - 1) == 0x0A
                ? lineEnd - 1 : lineEnd
            let content = NSRange(location: match.range.upperBound, length: contentEnd - match.range.upperBound)
            if content.length > 0 { spans.append(.init(kind: .checked, range: content)) }
        }
        for match in rule.matches(in: text, range: whole) {
            markers.append(match.range)
        }
        for match in strong.matches(in: text, range: whole) {
            spans.append(.init(kind: .strong, range: match.range))
            markers.append(contentsOf: [match.range(at: 1), match.range(at: 3)])
        }
        for match in code.matches(in: text, range: whole) {
            spans.append(.init(kind: .code, range: match.range))
            markers.append(contentsOf: [match.range(at: 1), match.range(at: 3)])
        }

        return spans + markers.map { .init(kind: .marker, range: $0) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}
