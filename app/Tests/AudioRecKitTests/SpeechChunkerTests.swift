import Foundation
import Testing

@testable import AudioRecKit

@Suite("発話のかたまり切り出し")
struct SpeechChunkerTests {

    private let sampleRate: Double = 16_000

    /// 指定秒数の音（サイン波）を作る。
    private func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { i in
            Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate)) * amplitude
        }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * seconds))
    }

    /// 実際のマイクのように 0.1 秒ずつ流し込む。
    private func stream(
        _ chunker: inout SpeechChunker, _ samples: [Float], step: Double = 0.1
    ) -> [SpeechChunker.Chunk] {
        let frames = Int(sampleRate * step)
        var produced: [SpeechChunker.Chunk] = []
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + frames)
            produced.append(contentsOf: chunker.append(Array(samples[index..<end])))
            index = end
        }
        return produced
    }

    @Test("無音だけでは何も出さない")
    func silenceProducesNothing() {
        // ここが崩れると Whisper に無音が渡り、定型句をでっち上げる
        var chunker = SpeechChunker()
        #expect(stream(&chunker, silence(3.0)).count == 0)
        #expect(chunker.flush() == nil)
    }

    @Test("発話のあと十分な無音が来たら切り出す")
    func cutsAfterSilence() {
        var chunker = SpeechChunker()
        let chunks = stream(&chunker, speech(2.0) + silence(1.0))

        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
        // 発話ぶんに末尾の無音が少し付く
        let duration = Double(chunks[0].samples.count) / sampleRate
        #expect(duration >= 2.0)
        #expect(duration < 3.2)
    }

    @Test("短い無音では切らない")
    func keepsShortPausesTogether() {
        // 文中の息継ぎで切ると前後の文脈が失われて精度が落ちる
        var chunker = SpeechChunker()
        let chunks = stream(&chunker, speech(1.0) + silence(0.3) + speech(1.0) + silence(1.0))

        #expect(chunks.count == 1)
    }

    @Test("複数の発話をそれぞれ切り出す")
    func cutsMultipleUtterances() {
        var chunker = SpeechChunker()
        let audio = speech(1.5) + silence(1.0) + speech(1.5) + silence(1.0)
        let chunks = stream(&chunker, audio)

        #expect(chunks.count == 2)
        // 2 つ目のかたまりは 1 つ目より後の時刻から始まる
        #expect(chunks[1].start > chunks[0].start)
    }

    @Test("切り出しの開始時刻が元の時間軸に対応する")
    func chunkStartsMapToTimeline() {
        var chunker = SpeechChunker()
        let chunks = stream(&chunker, silence(2.0) + speech(1.5) + silence(1.0))

        #expect(chunks.count == 1)
        // 先頭の無音も時間軸としては消費されている
        #expect(chunks[0].start >= 0)
        #expect(chunks[0].start < 3.0)
    }

    @Test("無音が来なくても上限の長さで切る")
    func cutsOnMaxLength() {
        // Whisper の入力窓は 30 秒。超える長さを渡すと後半が捨てられる。
        var configuration = SpeechChunker.Configuration()
        configuration.maxChunk = 3.0
        var chunker = SpeechChunker(configuration: configuration)

        let chunks = stream(&chunker, speech(10.0))

        #expect(chunks.count >= 3)
        for chunk in chunks {
            #expect(Double(chunk.samples.count) / sampleRate <= 3.2)
        }
    }

    @Test("短すぎる物音は捨てる")
    func ignoresBlips() {
        var chunker = SpeechChunker()
        let chunks = stream(&chunker, silence(0.5) + speech(0.2) + silence(1.0))

        #expect(chunks.count == 0)
    }

    @Test("録音終了時に残りを吐き出す")
    func flushEmitsRemainder() {
        // 末尾に無音が無いまま録音を止めても最後の発話を落とさない
        var chunker = SpeechChunker()
        _ = stream(&chunker, speech(1.5))

        let remainder = chunker.flush()
        #expect(remainder != nil)
        #expect(Double(remainder?.samples.count ?? 0) / sampleRate >= 1.4)
    }

    @Test("flush を二度呼んでも二重に出さない")
    func flushIsIdempotent() {
        var chunker = SpeechChunker()
        _ = stream(&chunker, speech(1.5))

        #expect(chunker.flush() != nil)
        #expect(chunker.flush() == nil)
    }

    @Test("空の入力を渡しても壊れない")
    func handlesEmptyInput() {
        var chunker = SpeechChunker()
        #expect(chunker.append([]).count == 0)
    }
}

@Suite("Whisper の信頼度換算")
struct WhisperConfidenceTests {

    @Test("平均対数確率を 0...1 に写す")
    func mapsLogProbToConfidence() {
        #expect(MLXWhisperEngine.confidence(fromAverageLogProb: 0.0) == 1.0)
        #expect(MLXWhisperEngine.confidence(fromAverageLogProb: -1.0) == 0.0)
        #expect(abs(MLXWhisperEngine.confidence(fromAverageLogProb: -0.5) - 0.5) < 0.001)
    }

    @Test("範囲外の値を丸める")
    func clampsOutOfRange() {
        #expect(MLXWhisperEngine.confidence(fromAverageLogProb: -5.0) == 0.0)
        #expect(MLXWhisperEngine.confidence(fromAverageLogProb: 1.0) == 1.0)
    }
}
