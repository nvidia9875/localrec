import Foundation

/// 文字起こしを `claude -p` で整形する。
///
/// タイムスタンプと話者ラベルは音声から得た事実なので、テキストだけを差し替える。
/// そのため「セグメントの配列を渡し、同じ長さの配列を受け取る」契約にしている。
/// 長さが合わない応答は棄却して元のまま残す。整形に失敗しても、
/// 元の文字起こしが壊れることは無い。
public struct TranscriptPolisher: Sendable {

    /// 1 回のリクエストに含めるセグメント数。
    /// 多すぎると応答が途中で切れたり、要素の対応がずれたりする。
    public static let chunkSize = 40

    private let runner: any ClaudeRunner
    private let glossary: Glossary

    public init(runner: any ClaudeRunner, glossary: Glossary = .empty) {
        self.runner = runner
        self.glossary = glossary
    }

    /// 整形した文字起こしを返す。時刻・話者・信頼度は元のまま。
    public func polish(_ transcript: Transcript) async throws -> Transcript {
        guard !transcript.isEmpty else { return transcript }

        var polished: [TranscriptSegment] = []
        for chunk in transcript.segments.chunked(into: Self.chunkSize) {
            let texts = chunk.map(\.text)
            let cleaned = try await polishTexts(texts)

            // 数が合わない応答は信用しない。ずれたまま採用すると
            // 発言と時刻・話者の対応が崩れ、元に戻せなくなる。
            guard cleaned.count == texts.count else {
                throw PostprocessError.segmentCountMismatch(
                    expected: texts.count, actual: cleaned.count)
            }

            for (segment, text) in zip(chunk, cleaned) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 空になった発話は元を残す。消してしまうと情報が失われる。
                polished.append(trimmed.isEmpty ? segment : segment.with(text: trimmed))
            }
        }
        return Transcript(segments: polished)
    }

    private func polishTexts(_ texts: [String]) async throws -> [String] {
        let input = try Self.encode(texts)
        let response = try await runner.run(prompt: Prompts.polish(glossary: glossary), input: input)
        return try Self.decode(response)
    }

    // MARK: - 受け渡し

    static func encode(_ texts: [String]) throws -> String {
        let data = try JSONEncoder().encode(texts)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PostprocessError.encodingFailed
        }
        return string
    }

    /// 応答から JSON 配列を取り出す。
    ///
    /// 「出力は JSON のみ」と指示していても、コードフェンスや前置きが
    /// 付いてくることがある。素直にパースできなければ、最初の `[` から
    /// 最後の `]` までを切り出して試す。
    static func decode(_ response: String) throws -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let array = try? JSONDecoder().decode([String].self, from: Data(trimmed.utf8)) {
            return array
        }

        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"), start < end
        else {
            throw PostprocessError.notJSONArray(String(trimmed.prefix(200)))
        }

        let slice = String(trimmed[start...end])
        guard let array = try? JSONDecoder().decode([String].self, from: Data(slice.utf8)) else {
            throw PostprocessError.notJSONArray(String(slice.prefix(200)))
        }
        return array
    }
}

public enum PostprocessError: LocalizedError, Equatable {
    case segmentCountMismatch(expected: Int, actual: Int)
    case notJSONArray(String)
    case encodingFailed
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .segmentCountMismatch(let expected, let actual):
            "整形結果の件数が合いません (期待 \(expected) / 実際 \(actual))。元の文字起こしを残しました。"
        case .notJSONArray(let preview):
            "整形結果を解釈できませんでした: \(preview)"
        case .encodingFailed:
            "整形リクエストを組み立てられませんでした"
        case .emptyResponse:
            "応答が空でした"
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
