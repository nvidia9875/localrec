import Foundation

/// 文字起こしから要約レポートを作る。
public struct SummaryGenerator: Sendable {

    private let runner: any ClaudeRunner

    public init(runner: any ClaudeRunner) {
        self.runner = runner
    }

    /// Markdown の要約レポートを返す。
    ///
    /// - Parameter memo: 人が書いたメモ。文字起こしに現れない決定事項を拾うために添える。
    ///   録音を回さずメモだけ取った打合せもあるので、メモだけでも要約する。
    public func summarize(
        _ transcript: Transcript, meta: RecordingMeta, memo: String = ""
    ) async throws -> String {
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || !trimmedMemo.isEmpty else {
            throw PostprocessError.emptyResponse
        }

        let prompt = Prompts.summarize(
            title: meta.title,
            date: Self.dateFormatter.string(from: meta.createdAt),
            duration: TimeCode.duration(meta.duration),
            participants: meta.participants,
            hasMemo: !trimmedMemo.isEmpty)

        let response = try await runner.run(
            prompt: prompt, input: Self.body(transcript, memo: trimmedMemo))

        let cleaned = Self.stripCodeFence(response)
        guard !cleaned.isEmpty else { throw PostprocessError.emptyResponse }
        return cleaned
    }

    /// claude に渡す本文。メモと文字起こしを節で分ける。
    /// 混ぜてしまうと、要約に出てきた記述の出所 (人が書いた / 話された) が分からなくなる。
    static func body(_ transcript: Transcript, memo: String) -> String {
        var sections: [String] = []
        if !memo.isEmpty {
            sections.append("## 会議メモ（人が書いた補足）\n\n\(memo)")
        }
        if !transcript.isEmpty {
            // タイムスタンプ付きで渡す。要約に [mm:ss] の参照を入れさせるため。
            sections.append("## 文字起こし\n\n\(TranscriptFormatter.markdown(transcript))")
        }
        return sections.joined(separator: "\n\n")
    }

    /// 「Markdown のみ」と指示していてもコードフェンスで包まれることがある。
    /// そのまま保存すると、要約ファイル全体が 1 つのコードブロックになってしまう。
    static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}
