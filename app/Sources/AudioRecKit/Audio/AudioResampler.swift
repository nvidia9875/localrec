import AVFoundation
import Foundation

/// マイクの生フォーマット (通常 48kHz float32) を
/// ASR が要求する 16kHz mono Int16 に変換する。
///
/// Whisper も Apple の SpeechAnalyzer も内部的に 16kHz を前提にしているため、
/// 保管用の音声とは別に、この形式のファイルを並行して書き出しておく。
public final class AudioResampler {
    /// メモリ上で扱う ASR 用フォーマット: 16kHz mono の float32 (非インターリーブ)。
    ///
    /// ディスク上は Int16 の WAV にするが、`AVAudioFile` の processingFormat は
    /// 既定で float32 非インターリーブになる。バッファをこれに合わせておかないと
    /// `write(from:)` が内部アサーションで落ちる (SIGTRAP)。
    /// SpeechAnalyzer に流すのもこの形式が扱いやすい。
    public static func asrFormat(sampleRate: Double = 16_000) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// ディスクに書く WAV の設定: 16kHz mono / 16bit PCM。
    /// Whisper 系のツールがそのまま読める、最も無難な形式。
    public static func asrFileSettings(sampleRate: Double = 16_000) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        // 品質より遅延と CPU を優先する。録音と同時に走るため。
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// 1 バッファ分を変換する。変換結果が 0 フレームなら nil を返す。
    public func resample(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        // 端数で 1 フレーム足りなくなることがあるので少し多めに確保する
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioResamplerError.bufferAllocationFailed
        }

        // AVAudioConverter は「入力を要求されたら渡す」プル方式。
        // 1 バッファにつき 1 回だけ渡し、2 回目以降は endOfStream を返す。
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw AudioResamplerError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw AudioResamplerError.conversionFailed("AVAudioConverter がエラーを返しました")
        }
        return output.frameLength > 0 ? output : nil
    }
}

public enum AudioResamplerError: LocalizedError {
    case bufferAllocationFailed
    case conversionFailed(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:
            "音声バッファを確保できませんでした"
        case .conversionFailed(let detail):
            "音声形式の変換に失敗しました: \(detail)"
        case .unsupportedFormat(let detail):
            "対応していない音声形式です: \(detail)"
        }
    }
}
