import Foundation

/// 流れてくる音声を、無音を境にした発話のかたまりに切り出す。
///
/// Whisper はファイル単位で動くので、リアルタイムに近い体験を作るには
/// 「区切りのよいところまで溜まったら投げる」必要がある。文の途中で
/// 切ると前後の文脈が失われて精度が落ちるため、無音を境界に使う。
///
/// 無音を渡さないことは、Whisper が無音に対して定型句をでっち上げる
/// 問題への対策も兼ねている。
public struct SpeechChunker {

    public struct Chunk: Sendable {
        public let samples: [Float]
        /// 録音開始からの秒数。文字起こし結果の時刻をここに足して元の時間軸に戻す。
        public let start: TimeInterval
    }

    public struct Configuration: Sendable {
        /// 無音とみなす RMS のしきい値。
        public var silenceThreshold: Float = 0.01
        /// この長さの無音が続いたら区切る。短すぎると文の途中で切れる。
        public var minSilence: TimeInterval = 0.6
        /// これより短い発話は雑音とみなして捨てる。
        public var minSpeech: TimeInterval = 0.8
        /// 無音が来なくてもこの長さで強制的に切る。
        /// Whisper の入力窓が 30 秒なので、それを超えないようにする。
        public var maxChunk: TimeInterval = 25

        public init() {}
    }

    private let sampleRate: Double
    private let configuration: Configuration

    private var pending: [Float] = []
    /// pending の先頭が録音開始から何秒目か。
    private var pendingStart: TimeInterval = 0
    private var consumed: TimeInterval = 0
    private var trailingSilence: TimeInterval = 0
    /// 溜まっている音声のうち、発話だった長さ。
    /// バッファ全体の長さで判定すると、前後の無音だけで最小長を超えてしまい、
    /// 一瞬の物音が発話として切り出されてしまう。
    private var speechDuration: TimeInterval = 0

    public init(sampleRate: Double = 16_000, configuration: Configuration = Configuration()) {
        self.sampleRate = sampleRate
        self.configuration = configuration
    }

    /// 音声を追加し、切り出せたかたまりを返す。
    public mutating func append(_ samples: [Float]) -> [Chunk] {
        guard !samples.isEmpty else { return [] }

        if pending.isEmpty {
            pendingStart = consumed
        }
        pending.append(contentsOf: samples)
        consumed += Double(samples.count) / sampleRate

        let level = Self.rms(samples)
        let duration = Double(samples.count) / sampleRate
        if level >= configuration.silenceThreshold {
            speechDuration += duration
            trailingSilence = 0
        } else {
            trailingSilence += duration
        }

        var chunks: [Chunk] = []

        let pendingDuration = Double(pending.count) / sampleRate
        let endedBySilence = speechDuration > 0 && trailingSilence >= configuration.minSilence
        let endedByLength = pendingDuration >= configuration.maxChunk

        if endedBySilence || endedByLength {
            if let chunk = takeChunk(enforceMinimum: true) { chunks.append(chunk) }
        }
        return chunks
    }

    /// 録音終了時に、残っている音声を吐き出す。
    /// 最小長は課さない。末尾の短い一言を落とすより残す方がよいため。
    public mutating func flush() -> Chunk? {
        takeChunk(enforceMinimum: false)
    }

    private mutating func takeChunk(enforceMinimum: Bool) -> Chunk? {
        defer {
            pending.removeAll(keepingCapacity: true)
            pendingStart = consumed
            trailingSilence = 0
            speechDuration = 0
        }

        // 無音しか入っていないかたまりは投げない。
        // Whisper に無音を渡すと定型句をでっち上げる。
        guard speechDuration > 0, !pending.isEmpty else { return nil }
        // 一瞬の物音を発話として拾わない。判定に使うのは発話ぶんの長さ。
        if enforceMinimum, speechDuration < configuration.minSpeech { return nil }

        return Chunk(samples: pending, start: pendingStart)
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
