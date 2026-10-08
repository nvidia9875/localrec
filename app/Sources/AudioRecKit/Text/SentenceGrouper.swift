import Foundation

/// 時間情報を持つテキスト片。エンジンが返す語・句に対応する。
public struct TimedToken: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// 語単位のトークンを文単位にまとめる。
///
/// エンジンは 10 秒分の音声を 1 つの結果として返してくることがある。
/// そのまま 1 セグメントにすると、Notion 風の「行ごとにタイムスタンプ」が
/// 成立せず、再生位置との同期も粗くなる。文末で切って行を作る。
public enum SentenceGrouper {

    /// 文の区切りとみなす文字。
    static let terminators: Set<Character> = ["。", "！", "？", "!", "?"]

    /// 句読点が全く現れない話し方もあるため、この長さを超えたら強制的に切る。
    public static let defaultMaxDuration: TimeInterval = 20

    public static func group(
        _ tokens: [TimedToken],
        maxDuration: TimeInterval = defaultMaxDuration
    ) -> [TimedToken] {
        let exploded = explode(tokens)
        guard !exploded.isEmpty else { return [] }

        var sentences: [TimedToken] = []
        var buffer: [TimedToken] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = buffer.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sentences.append(TimedToken(text: text, start: first.start, end: last.end))
            }
            buffer.removeAll()
        }

        for token in exploded {
            buffer.append(token)

            let endsSentence = token.text.last.map { terminators.contains($0) } ?? false
            let tooLong = (token.end - (buffer.first?.start ?? token.start)) >= maxDuration
            if endsSentence || tooLong {
                flush()
            }
        }
        flush()

        return sentences
    }

    /// トークンの途中に文末記号が含まれている場合に、そこで切り分ける。
    /// 時刻は文字数で按分する。1 トークンが複数の文にまたがっていても
    /// 行のタイムスタンプが極端にずれないようにするため。
    static func explode(_ tokens: [TimedToken]) -> [TimedToken] {
        var result: [TimedToken] = []

        for token in tokens {
            let characters = Array(token.text)
            guard characters.count > 1,
                  characters.dropLast().contains(where: { terminators.contains($0) })
            else {
                if !token.text.isEmpty { result.append(token) }
                continue
            }

            var pieceStartIndex = 0
            for (offset, character) in characters.enumerated() where terminators.contains(character) {
                let piece = String(characters[pieceStartIndex...offset])
                result.append(
                    interpolated(token, from: pieceStartIndex, to: offset + 1, total: characters.count, text: piece))
                pieceStartIndex = offset + 1
            }
            if pieceStartIndex < characters.count {
                let piece = String(characters[pieceStartIndex...])
                result.append(
                    interpolated(token, from: pieceStartIndex, to: characters.count, total: characters.count, text: piece))
            }
        }
        return result
    }

    private static func interpolated(
        _ token: TimedToken, from: Int, to: Int, total: Int, text: String
    ) -> TimedToken {
        guard total > 0 else { return token }
        let span = token.end - token.start
        return TimedToken(
            text: text,
            start: token.start + span * Double(from) / Double(total),
            end: token.start + span * Double(to) / Double(total)
        )
    }
}
