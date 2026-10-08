import AudioRecKit
import Foundation

/// `claude -p` による整形と要約を、実際に CLI を呼んで確かめる。
///
/// 単体テストはスタブで契約を検証しているが、実際のモデルが
/// 「JSON 配列のみを返す」「件数を保つ」という約束を守るかは
/// 呼んでみないと分からない。
///
/// 使い方:
///   AudioRec --postprocesstest [--model sonnet]
@MainActor
enum PostprocessSelfTest {

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--postprocesstest")
    }

    static func run(model: String) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        var ok = true
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "  ✔" : "  ✘") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { ok = false }
        }

        print("claude -p 後処理の診断 (model: \(model))")

        print("\n[1/3] claude コマンド")
        guard let executable = ClaudeCLI.discover() else {
            check("見つかった", false)
            print("\n" + (ClaudeCLIError.notInstalled.errorDescription ?? ""))
            return false
        }
        check("見つかった", true, executable.path)

        let runner = ClaudeCLI(
            configuration: .init(executable: executable, model: model, timeout: 180))
        let original = Self.sampleTranscript

        print("\n[2/3] 整形")
        let polished: Transcript
        do {
            polished = try await TranscriptPolisher(runner: runner, glossary: Self.glossary)
                .polish(original)
        } catch {
            check("整形できた", false, error.localizedDescription)
            return false
        }

        check("件数が保たれている", polished.segments.count == original.segments.count,
              "\(original.segments.count) → \(polished.segments.count)")
        // 時刻と話者は音声から得た事実なので、整形で変わってはいけない
        check("時刻が変わっていない",
              polished.segments.map(\.start) == original.segments.map(\.start))
        check("話者が変わっていない",
              polished.segments.map(\.speaker) == original.segments.map(\.speaker))
        check("テキストが実際に変わった",
              polished.segments.map(\.text) != original.segments.map(\.text))

        for (before, after) in zip(original.segments, polished.segments) {
            print("    [\(TimeCode.short(before.start))] \(before.text)")
            print("      → \(after.text)")
        }

        print("\n[3/3] 要約（登場人物とメモ入り）")
        let meta = RecordingMeta(
            id: "diagnostic", title: "設計レビュー", createdAt: Date(), duration: 1920,
            tracks: [.mic, .system], engine: .apple,
            participants: Self.participants)
        let summary: String
        do {
            summary = try await SummaryGenerator(runner: runner)
                .summarize(polished, meta: meta, memo: Self.sampleMemo)
        } catch {
            check("要約できた", false, error.localizedDescription)
            return false
        }

        check("Markdown が返った", summary.contains("#"), "\(summary.count) 文字")
        // メモにしか書いていない事実。落ちていればメモが読まれていない
        check("メモの内容が反映されている", summary.contains("CER"))
        check("登場人物の表記が使われている",
              Self.participants.contains { summary.contains($0) })
        // コードフェンスで包まれたまま保存すると、全体が 1 つのコードブロックになる
        check("コードフェンスが残っていない", !summary.hasPrefix("```"))

        let blocks = MarkdownBlocks.parse(summary)
        check("ブロックに分解できた", !blocks.isEmpty, "\(blocks.count) ブロック")

        print("\n--- 要約 ---")
        print(summary)

        print("\n\(ok ? "すべて通過しました" : "失敗した項目があります")")
        return ok
    }

    private static let glossary = Glossary(terms: ["鴻上", "プルリクエスト"])

    private static let participants = ["鴻上", "坂井駿介"]

    /// 文字起こしには出てこない事実だけを書いたメモ。
    /// 要約にこれが出れば、メモが材料として読まれたと言える。
    private static let sampleMemo = """
        - 次回までに CER の実測値を出す（担当: 坂井駿介）
        - 予算は8月末に確定見込み
        """

    /// フィラーと言い淀みを意図的に含めた見本。
    private static var sampleTranscript: Transcript {
        Transcript(segments: [
            seg(0, 8, .mySelf, "えーと、それでは、あの、設計レビューを始めさせていただきます。"),
            seg(8, 18, .other, "はい、はい、よろしくお願いします。えっと、資料は事前に見ました。"),
            seg(18, 32, .mySelf, "ありがとうございます。その、まず全体構成なんですけれども、音声の取り込みをマイクとシステム音声の2トラックに分けています。"),
            seg(32, 44, .other, "なんというか、2トラックに分ける理由をもう少し詳しく教えてもらえますか。"),
            seg(44, 60, .mySelf, "混ぜてしまうと誰が話したかが判別できなくなるんですよね。マイク側は自分、システム側は相手と決め打ちできます。"),
            seg(60, 70, .other, "なるほど、まあ、それは実装コストがだいぶ下がりますね。"),
            seg(70, 82, .mySelf, "はい。あと、鴻上さんにプルリクエストのレビューをお願いしておきます。"),
            seg(82, 92, .other, "了解しました。では水曜の午後にもう一度すり合わせましょう。"),
        ])
    }

    private static func seg(
        _ start: TimeInterval, _ end: TimeInterval, _ speaker: SpeakerRole, _ text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start, end: end, speaker: speaker, text: text,
            confidence: 0.93, engine: .apple)
    }
}
