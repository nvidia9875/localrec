import AVFoundation
import Foundation

/// 1 トラック分の音声を 2 つの形式で書き出す。
///
/// - 保管用の m4a (AAC): 長時間でも容量が現実的
/// - ASR 用の 16kHz mono WAV: Whisper も SpeechAnalyzer もこの形式が前提
///
/// マイクとシステム音声で同じ処理が要るので、ここに切り出してある。
public final class TrackWriter {

    /// 書き込んだ入力フレーム数。録音長の算出に使う。
    public private(set) var framesWritten: AVAudioFrameCount = 0

    private let sourceFormat: AVAudioFormat
    private var storageFile: AVAudioFile?
    private var asrFile: AVAudioFile?
    private let resampler: AudioResampler

    public init(storageURL: URL, asrURL: URL, sourceFormat: AVAudioFormat) throws {
        self.sourceFormat = sourceFormat

        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            storageFile = try AVAudioFile(
                forWriting: storageURL,
                settings: Self.aacSettings(from: sourceFormat),
                commonFormat: .pcmFormatFloat32,
                interleaved: sourceFormat.isInterleaved
            )
        } catch {
            throw MicRecorderError.fileCreationFailed("m4a: \(error.localizedDescription)")
        }

        guard let resampler = AudioResampler(
            inputFormat: sourceFormat, outputFormat: AudioResampler.asrFormat())
        else {
            throw MicRecorderError.fileCreationFailed("16kHz への変換器を作れませんでした")
        }
        self.resampler = resampler

        do {
            // ファイル形式は Int16 の WAV、メモリ上の処理形式は float32。
            // 後者をリサンプラの出力と一致させないと write(from:) が落ちる。
            asrFile = try AVAudioFile(
                forWriting: asrURL,
                settings: AudioResampler.asrFileSettings(),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MicRecorderError.fileCreationFailed("wav: \(error.localizedDescription)")
        }
    }

    /// 1 バッファ分を書き、ASR に流すための 16kHz mono バッファを返す。
    @discardableResult
    public func write(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        try Self.write(buffer, to: storageFile, label: "m4a")
        framesWritten += buffer.frameLength

        guard let resampled = try resampler.resample(buffer) else { return nil }
        try Self.write(resampled, to: asrFile, label: "wav")
        return resampled
    }

    public func close() {
        // AVAudioFile はデイニシャライズ時にファイルを閉じる
        storageFile = nil
        asrFile = nil
    }

    /// 録音した長さ（秒）。入力フレーム数から算出する。
    public var duration: TimeInterval {
        guard sourceFormat.sampleRate > 0 else { return 0 }
        return Double(framesWritten) / sourceFormat.sampleRate
    }

    // MARK: - 内部

    /// フォーマットを確かめてから書く。
    ///
    /// `AVAudioFile.write(from:)` にバッファの形式が processingFormat と違うものを渡すと、
    /// 例外ではなく内部アサーション (SIGTRAP) でプロセスごと落ちる。
    /// オーディオスレッドで起きるとクラッシュログしか残らないので、手前で弾いて
    /// 通常のエラーとして扱う。
    private static func write(
        _ buffer: AVAudioPCMBuffer, to file: AVAudioFile?, label: String
    ) throws {
        guard let file else { return }
        let expected = file.processingFormat
        guard buffer.format.sampleRate == expected.sampleRate,
              buffer.format.channelCount == expected.channelCount,
              buffer.format.commonFormat == expected.commonFormat,
              buffer.format.isInterleaved == expected.isInterleaved
        else {
            throw MicRecorderError.formatMismatch(
                label: label,
                expected: describe(expected),
                actual: describe(buffer.format))
        }
        try file.write(from: buffer)
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz \(format.channelCount)ch "
            + "\(format.commonFormat.rawValue) "
            + (format.isInterleaved ? "interleaved" : "non-interleaved")
    }

    private static func aacSettings(from format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
    }
}
