import Foundation
import Testing

@testable import AudioRecKit

/// 応答を固定して返すスタブ。実際に claude を呼ばずに契約を検証する。
private struct StubRunner: ClaudeRunner {
    /// nil のときは入力の配列をそのまま返す（件数の整合を保ちたいテスト用）
    let response: String?
    var error: (any Error)?
    /// 受け取った入力を確認したいテスト用
    final class Recorder: @unchecked Sendable {
        var lastPrompt = ""
        var lastInput = ""
        var callCount = 0
    }
    let recorder = Recorder()

    func run(prompt: String, input: String) async throws -> String {
        recorder.lastPrompt = prompt
        recorder.lastInput = input
        recorder.callCount += 1
        if let error { throw error }
        return response ?? input
    }
}

@Suite("文字起こしの整形")
struct TranscriptPolisherTests {

    private func transcript(_ texts: [String]) -> Transcript {
        Transcript(segments: texts.enumerated().map { index, text in
            TranscriptSegment(
                start: TimeInterval(index) * 5,
                end: TimeInterval(index) * 5 + 4,
                speaker: index.isMultiple(of: 2) ? .mySelf : .other,
                text: text,
                confidence: 0.9,
                engine: .apple)
        })
    }

    @Test("整形後もテキストだけが差し替わる")
    func replacesOnlyText() async throws {
        let original = transcript(["えーと、はい。", "あの、そうですね。"])
        let runner = StubRunner(response: #"["はい。","そうですね。"]"#)
        let polished = try await TranscriptPolisher(runner: runner).polish(original)

        #expect(polished.segments.map(\.text) == ["はい。", "そうですね。"])
        // 時刻・話者・信頼度は音声から得た事実なので変わってはいけない
        #expect(polished.segments.map(\.start) == original.segments.map(\.start))
        #expect(polished.segments.map(\.end) == original.segments.map(\.end))
        #expect(polished.segments.map(\.speaker) == original.segments.map(\.speaker))
        #expect(polished.segments.map(\.confidence) == original.segments.map(\.confidence))
        #expect(polished.segments.map(\.id) == original.segments.map(\.id))
    }

    @Test("件数が合わない応答は棄却する")
    func rejectsCountMismatch() async {
        // ずれたまま採用すると、発言と時刻・話者の対応が崩れて元に戻せない
        let runner = StubRunner(response: #"["ひとつだけ"]"#)
        let polisher = TranscriptPolisher(runner: runner)

        await #expect(throws: PostprocessError.segmentCountMismatch(expected: 2, actual: 1)) {
            _ = try await polisher.polish(transcript(["あ", "い"]))
        }
    }

    @Test("コードフェンス付きの応答も読める")
    func toleratesCodeFence() async throws {
        // 「JSON のみ」と指示してもフェンスが付いてくることがある
        let runner = StubRunner(response: "```json\n[\"はい。\"]\n```")
        let polished = try await TranscriptPolisher(runner: runner).polish(transcript(["えー、はい"]))

        #expect(polished.segments.first?.text == "はい。")
    }

    @Test("前置き付きの応答からも配列を取り出す")
    func toleratesPreamble() async throws {
        let runner = StubRunner(response: "整形しました:\n[\"はい。\"]")
        let polished = try await TranscriptPolisher(runner: runner).polish(transcript(["えー、はい"]))

        #expect(polished.segments.first?.text == "はい。")
    }

    @Test("空文字になった発話は元を残す")
    func keepsOriginalWhenCleanedToEmpty() async throws {
        // 相槌だけの発話が消えると情報が失われる
        let runner = StubRunner(response: #"["",""]"#)
        let polished = try await TranscriptPolisher(runner: runner).polish(transcript(["うん", "はい"]))

        #expect(polished.segments.map(\.text) == ["うん", "はい"])
    }

    @Test("配列でない応答はエラーにする")
    func rejectsNonArray() async {
        let runner = StubRunner(response: "すみません、整形できませんでした。")
        let polisher = TranscriptPolisher(runner: runner)

        await #expect(throws: (any Error).self) {
            _ = try await polisher.polish(transcript(["あ"]))
        }
    }

    @Test("空の文字起こしは呼び出さずにそのまま返す")
    func skipsEmptyTranscript() async throws {
        let runner = StubRunner(response: "[]")
        let polished = try await TranscriptPolisher(runner: runner).polish(.empty)

        #expect(polished.isEmpty)
        #expect(runner.recorder.callCount == 0)
    }

    @Test("長い文字起こしは分割して送る")
    func chunksLongTranscripts() async throws {
        // 1 回に詰め込みすぎると応答が途中で切れ、要素の対応がずれる
        let count = TranscriptPolisher.chunkSize + 5
        let texts = (0..<count).map { "発話\($0)" }
        // 入力をそのまま返すスタブ。件数が合うので最後まで処理が進む。
        let runner = StubRunner(response: nil)
        let polished = try await TranscriptPolisher(runner: runner).polish(transcript(texts))

        #expect(runner.recorder.callCount == 2)
        #expect(polished.segments.count == count)
        #expect(polished.segments.map(\.text) == texts)
    }

    @Test("用語辞書があればプロンプトに載せる")
    func includesGlossaryTerms() async throws {
        let runner = StubRunner(response: #"["はい"]"#)
        let glossary = Glossary(terms: ["鴻上", "プルリクエスト"])
        _ = try await TranscriptPolisher(runner: runner, glossary: glossary).polish(transcript(["はい"]))

        #expect(runner.recorder.lastPrompt.contains("鴻上"))
        #expect(runner.recorder.lastPrompt.contains("プルリクエスト"))
    }

    @Test("入力は JSON 配列として渡す")
    func sendsJSONArray() async throws {
        let runner = StubRunner(response: #"["a","b"]"#)
        _ = try await TranscriptPolisher(runner: runner).polish(transcript(["あ", "い"]))

        let decoded = try JSONDecoder().decode([String].self, from: Data(runner.recorder.lastInput.utf8))
        #expect(decoded == ["あ", "い"])
    }
}

@Suite("要約の生成")
struct SummaryGeneratorTests {

    private let meta = RecordingMeta(
        id: "id", title: "設計レビュー", createdAt: Date(timeIntervalSince1970: 1_786_000_000),
        duration: 1920)

    private var sample: Transcript {
        Transcript(segments: [TranscriptSegment(start: 0, end: 3, text: "始めます")])
    }

    @Test("Markdown をそのまま返す")
    func returnsMarkdown() async throws {
        let runner = StubRunner(response: "# まとめ\n\n- 決定事項")
        let summary = try await SummaryGenerator(runner: runner).summarize(sample, meta: meta)

        #expect(summary == "# まとめ\n\n- 決定事項")
    }

    @Test("コードフェンスを剥がす")
    func stripsCodeFence() async throws {
        // 剥がさないと要約ファイル全体が 1 つのコードブロックになる
        let runner = StubRunner(response: "```markdown\n# まとめ\n```")
        let summary = try await SummaryGenerator(runner: runner).summarize(sample, meta: meta)

        #expect(summary == "# まとめ")
    }

    @Test("空の文字起こしは要約しない")
    func rejectsEmptyTranscript() async {
        let runner = StubRunner(response: "# まとめ")
        await #expect(throws: PostprocessError.emptyResponse) {
            _ = try await SummaryGenerator(runner: runner).summarize(.empty, meta: meta)
        }
    }

    @Test("タイムスタンプ付きの本文を渡す")
    func sendsTimestampedBody() async throws {
        // 要約に [mm:ss] の参照を入れさせるため
        let runner = StubRunner(response: "# まとめ")
        _ = try await SummaryGenerator(runner: runner).summarize(sample, meta: meta)

        #expect(runner.recorder.lastInput.contains("[00:00]"))
    }

    @Test("プロンプトにタイトルと長さを載せる")
    func includesMetadataInPrompt() async throws {
        let runner = StubRunner(response: "# まとめ")
        _ = try await SummaryGenerator(runner: runner).summarize(sample, meta: meta)

        #expect(runner.recorder.lastPrompt.contains("設計レビュー"))
        #expect(runner.recorder.lastPrompt.contains("32分"))
    }

    @Test("登場人物をプロンプトに載せる")
    func includesParticipantsInPrompt() async throws {
        // 人名は誤変換されやすい。正しい表記を先に渡しておけば要約側で直せる。
        let runner = StubRunner(response: "# まとめ")
        let withPeople = meta.with(participants: ["山田太郎", "坂井駿介"])
        _ = try await SummaryGenerator(runner: runner).summarize(sample, meta: withPeople)

        #expect(runner.recorder.lastPrompt.contains("山田太郎"))
        #expect(runner.recorder.lastPrompt.contains("坂井駿介"))
    }

    @Test("メモを本文に添えて渡す")
    func sendsMemoWithTranscript() async throws {
        let runner = StubRunner(response: "# まとめ")
        _ = try await SummaryGenerator(runner: runner)
            .summarize(sample, meta: meta, memo: "予算は来週確定")

        #expect(runner.recorder.lastInput.contains("予算は来週確定"))
        // 文字起こしと混ざると引用の出所が分からなくなる
        #expect(runner.recorder.lastInput.contains("会議メモ"))
        #expect(runner.recorder.lastInput.contains("[00:00]"))
        #expect(runner.recorder.lastPrompt.contains("会議メモ"))
    }

    @Test("メモが空なら節ごと付けない")
    func omitsEmptyMemo() async throws {
        let runner = StubRunner(response: "# まとめ")
        _ = try await SummaryGenerator(runner: runner).summarize(sample, meta: meta, memo: "   \n ")

        #expect(!runner.recorder.lastInput.contains("会議メモ"))
        #expect(!runner.recorder.lastPrompt.contains("会議メモ"))
    }

    @Test("文字起こしが空でもメモがあれば要約する")
    func summarizesFromMemoAlone() async throws {
        // 録音を回さずメモだけ取った打合せでもレポートは作りたい
        let runner = StubRunner(response: "# まとめ")
        let summary = try await SummaryGenerator(runner: runner)
            .summarize(.empty, meta: meta, memo: "口頭で合意した")

        #expect(summary == "# まとめ")
        #expect(runner.recorder.lastInput.contains("口頭で合意した"))
    }

    @Test("文字起こしもメモも無ければ要約しない")
    func rejectsEmptyInput() async {
        let runner = StubRunner(response: "# まとめ")
        await #expect(throws: PostprocessError.emptyResponse) {
            _ = try await SummaryGenerator(runner: runner).summarize(.empty, meta: meta, memo: "")
        }
    }
}

@Suite("claude CLI の応答解釈")
struct ClaudeCLIResponseTests {

    @Test("封筒から本文を取り出す")
    func extractsResult() throws {
        let json = #"{"is_error":false,"result":"整形後のテキスト"}"#
        #expect(try ClaudeCLI.extractResult(from: Data(json.utf8)) == "整形後のテキスト")
    }

    @Test("エラー応答はエラーとして投げる")
    func throwsOnErrorEnvelope() {
        // ここを握り潰すと、失敗が「空の要約」として保存されてしまう
        let json = #"{"is_error":true,"result":"レート制限"}"#
        #expect(throws: (any Error).self) {
            _ = try ClaudeCLI.extractResult(from: Data(json.utf8))
        }
    }

    @Test("JSON でない出力はエラーにする")
    func throwsOnNonJSON() {
        #expect(throws: (any Error).self) {
            _ = try ClaudeCLI.extractResult(from: Data("not json".utf8))
        }
    }

    @Test("result が無い応答はエラーにする")
    func throwsWhenResultMissing() {
        #expect(throws: (any Error).self) {
            _ = try ClaudeCLI.extractResult(from: Data(#"{"is_error":false}"#.utf8))
        }
    }
}
