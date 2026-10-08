import Foundation
import Testing

@testable import AudioRecKit

@Suite("文字起こしモデル")
struct TranscriptTests {

    @Test("appending は元を変更せず新しい値を返す")
    func appendingIsImmutable() {
        let original = Transcript(segments: [seg(0, 1, "あ")])
        let appended = original.appending(seg(1, 2, "い"))

        #expect(original.segments.count == 1)
        #expect(appended.segments.count == 2)
    }

    @Test("replacing は ID 一致のセグメントだけ差し替える")
    func replacesByID() {
        let target = seg(0, 1, "誤り")
        let other = seg(1, 2, "そのまま")
        let transcript = Transcript(segments: [target, other])

        let fixed = transcript.replacing(id: target.id, with: target.with(text: "正しい", edited: true))

        #expect(fixed.segments[0].text == "正しい")
        #expect(fixed.segments[0].edited)
        #expect(fixed.segments[1].text == "そのまま")
    }

    @Test("該当 ID が無ければ内容は変わらない")
    func replacingUnknownIDIsNoop() {
        let transcript = Transcript(segments: [seg(0, 1, "あ")])
        #expect(transcript.replacing(id: UUID(), with: seg(0, 1, "い")) == transcript)
    }

    @Test("指定時刻を含むセグメントを引ける")
    func findsSegmentAtTime() {
        let transcript = Transcript(segments: [seg(0, 5, "前半"), seg(5, 10, "後半")])

        #expect(transcript.segment(at: 0)?.text == "前半")
        #expect(transcript.segment(at: 4.9)?.text == "前半")
        // 境界は次のセグメントに属する (end は排他)
        #expect(transcript.segment(at: 5)?.text == "後半")
        #expect(transcript.segment(at: 10) == nil)
    }

    @Test("with は指定した項目だけ差し替える")
    func withUpdatesOnlyGivenFields() {
        let original = TranscriptSegment(
            start: 1, end: 2, speaker: .mySelf, text: "元", confidence: 0.7, engine: .apple)
        let updated = original.with(text: "新")

        #expect(updated.text == "新")
        #expect(updated.id == original.id)
        #expect(updated.speaker == .mySelf)
        #expect(updated.confidence == 0.7)
        #expect(updated.engine == .apple)
        #expect(original.text == "元")
    }

    private func seg(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }
}

@Suite("文字起こしの書き出し")
struct TranscriptFormatterTests {

    @Test("話者ありの Markdown 行")
    func markdownLineWithSpeaker() {
        let line = TranscriptFormatter.line(
            for: TranscriptSegment(start: 72, end: 75, speaker: .other, text: "はい"))
        #expect(line == "[01:12] 相手: はい")
    }

    @Test("話者が unknown なら話者部分ごと省く")
    func markdownLineWithoutSpeaker() {
        let line = TranscriptFormatter.line(
            for: TranscriptSegment(start: 5, end: 6, speaker: .unknown, text: "メモ"))
        #expect(line == "[00:05] メモ")
    }

    @Test("メタデータがあれば見出しを付ける")
    func markdownIncludesHeader() {
        let meta = RecordingMeta(
            id: "id", title: "設計レビュー", createdAt: Date(), duration: 1920, engine: .mlx,
            model: "whisper-large-v3")
        let md = TranscriptFormatter.markdown(
            Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "本文")]), meta: meta)

        #expect(md.contains("# 設計レビュー"))
        #expect(md.contains("- 長さ: 32分"))
        #expect(md.contains("- エンジン: Whisper (MLX) (whisper-large-v3)"))
        #expect(md.contains("[00:00] 本文"))
    }

    @Test("登場人物がいれば見出しに載せる")
    func markdownIncludesParticipants() {
        // 書き出した md を人や claude が読むとき、誰の話かの手がかりになる
        let meta = RecordingMeta(
            id: "id", title: "定例", createdAt: Date(), duration: 600,
            participants: ["山田太郎", "坂井駿介"])
        let md = TranscriptFormatter.markdown(
            Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "本文")]), meta: meta)

        #expect(md.contains("- 登場人物: 山田太郎、坂井駿介"))
    }

    @Test("SRT は 1 始まりの連番を振る")
    func srtNumbersFromOne() {
        let srt = TranscriptFormatter.srt(
            Transcript(segments: [
                TranscriptSegment(start: 0, end: 1.5, speaker: .mySelf, text: "一つ目"),
                TranscriptSegment(start: 2, end: 3, speaker: .other, text: "二つ目"),
            ]))

        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\n自分: 一つ目"))
        #expect(srt.contains("2\n00:00:02,000 --> 00:00:03,000\n相手: 二つ目"))
    }

    @Test("空の文字起こしでも壊れない")
    func handlesEmptyTranscript() {
        #expect(TranscriptFormatter.srt(.empty) == "\n")
        #expect(TranscriptFormatter.markdown(.empty) == "\n")
    }
}
