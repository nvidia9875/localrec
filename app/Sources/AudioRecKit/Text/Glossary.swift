import Foundation

/// 用語辞書。両エンジンで共有する。
///
/// - `terms`: 認識を強化したい語 (人名・社名・製品名・専門用語)
///   - Apple:   `AnalysisContext.contextualStrings` に渡す
///   - Whisper: `initial_prompt` に列挙する
/// - `corrections`: それでも誤変換された場合の後段の置換
public struct Glossary: Codable, Sendable, Equatable {
    public let terms: [String]
    public let corrections: [String: String]

    public init(terms: [String] = [], corrections: [String: String] = [:]) {
        self.terms = terms
        self.corrections = corrections
    }

    public static let empty = Glossary()

    public var isEmpty: Bool { terms.isEmpty && corrections.isEmpty }

    /// Whisper の `initial_prompt` 用の文字列。
    /// Whisper は「直前の文脈」としてこれを読むので、単語の羅列より
    /// 日本語の文の体裁を保った方が効きがよい。
    public func whisperPrompt() -> String? {
        guard !terms.isEmpty else { return nil }
        return "以下の用語が登場します: " + terms.joined(separator: "、") + "。"
    }

    /// 誤変換を修正する。
    ///
    /// 日本語には語境界が無いので、単純な `replacingOccurrences` の連鎖は
    /// 2 つの事故を起こす:
    ///  1. 短い語が長い語の一部を食う (「AI」が「AIエージェント」を壊す)
    ///  2. 置換結果がさらに置換される連鎖 (A→B, B→C で A が C になる)
    ///
    /// そのため「最長一致を優先して 1 パスだけ走査する」実装にしている。
    public func applyCorrections(to text: String) -> String {
        guard !corrections.isEmpty else { return text }

        // 長いキーから順に試すことで、短い語による食い込みを防ぐ
        let keys = corrections.keys.sorted { $0.count > $1.count }
        let characters = Array(text)
        var result = ""
        var index = 0

        while index < characters.count {
            var matched = false
            for key in keys where !key.isEmpty {
                let keyChars = Array(key)
                guard index + keyChars.count <= characters.count else { continue }
                if Array(characters[index..<(index + keyChars.count)]) == keyChars {
                    // 置換後の文字列は再走査しない (連鎖置換の防止)
                    result += corrections[key] ?? ""
                    index += keyChars.count
                    matched = true
                    break
                }
            }
            if !matched {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    /// 用語を追加した新しい辞書を返す。重複は取り除く。
    public func adding(term: String) -> Glossary {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !terms.contains(trimmed) else { return self }
        return Glossary(terms: terms + [trimmed], corrections: corrections)
    }

    /// 誤変換の対応を追加した新しい辞書を返す。
    public func adding(correction wrong: String, to right: String) -> Glossary {
        let key = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != right else { return self }
        var updated = corrections
        updated[key] = right
        return Glossary(terms: terms, corrections: updated)
    }
}

// MARK: - 永続化

extension Glossary {
    /// `glossary.json` から読む。無い / 壊れている場合は空の辞書を返す。
    /// 辞書が読めないことで文字起こし全体を止める理由がないため。
    public static func load(from url: URL) -> Glossary {
        guard let data = try? Data(contentsOf: url),
              let glossary = try? JSONDecoder().decode(Glossary.self, from: data)
        else { return .empty }
        return glossary
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
