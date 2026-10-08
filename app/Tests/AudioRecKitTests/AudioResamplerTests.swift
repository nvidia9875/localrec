import AVFoundation
import Foundation
import Testing

@testable import AudioRecKit

@Suite("ASR 用のリサンプリング")
struct AudioResamplerTests {

    @Test("ASR フォーマットは 16kHz mono float32 の非インターリーブ")
    func asrFormatMatchesAVAudioFileProcessingFormat() throws {
        // AVAudioFile の processingFormat は既定でこの形になる。
        // ここがずれていると write(from:) が SIGTRAP でプロセスごと落ちる。
        let format = AudioResampler.asrFormat()

        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(!format.isInterleaved)
    }

    @Test("WAV ファイル設定は 16bit PCM")
    func wavSettingsAre16BitPCM() {
        let settings = AudioResampler.asrFileSettings()

        #expect(settings[AVSampleRateKey] as? Double == 16_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
    }

    @Test("書き出したファイルの processingFormat が asrFormat と一致する")
    func writtenFileProcessingFormatMatches() throws {
        // MicRecorder と同じ組み合わせでファイルを作り、実際に書けることを確かめる。
        // Phase 1 で実機がクラッシュした原因そのものを回帰テストにする。
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resampler-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioResampler.asrFileSettings(),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        #expect(file.processingFormat == AudioResampler.asrFormat())

        let buffer = Self.makeBuffer(format: AudioResampler.asrFormat(), frames: 1_600)
        try file.write(from: buffer)
        #expect(file.length == 1_600)
    }

    @Test("48kHz ステレオを 16kHz モノラルに落とせる")
    func resamples48kStereoTo16kMono() throws {
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let resampler = try #require(
            AudioResampler(inputFormat: input, outputFormat: AudioResampler.asrFormat()))

        let output = try #require(try resampler.resample(Self.makeBuffer(format: input, frames: 4_800)))

        #expect(output.format.sampleRate == 16_000)
        #expect(output.format.channelCount == 1)
        #expect(!output.format.isInterleaved)
        #expect(output.frameLength > 0)
    }

    @Test("連続して流すと出力量が 1/3 に収束する")
    func steadyStateOutputMatchesSampleRateRatio() throws {
        // 変換器は初回に内部遅延ぶん (16kHz で 200〜300 フレーム程度) 出力が短くなる。
        // 一度きりのズレなので、録音を通した合計では比率どおりに収束する必要がある。
        // ここが崩れると長時間録音でタイムスタンプが継続的にずれる。
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let resampler = try #require(
            AudioResampler(inputFormat: input, outputFormat: AudioResampler.asrFormat()))

        // 48kHz で 4800 フレーム × 10 回 = 1 秒 → 16kHz で 16000 フレーム
        var total = 0
        for _ in 0..<10 {
            let output = try resampler.resample(Self.makeBuffer(format: input, frames: 4_800))
            total += Int(output?.frameLength ?? 0)
        }

        let drift = abs(total - 16_000)
        #expect(drift < 400, "累積ズレ \(drift) フレーム (合計 \(total))")
    }

    @Test("同一フォーマットならフレーム数が保たれる")
    func passthroughKeepsFrameCount() throws {
        let format = AudioResampler.asrFormat()
        let resampler = try #require(AudioResampler(inputFormat: format, outputFormat: format))

        let output = try #require(try resampler.resample(Self.makeBuffer(format: format, frames: 800)))
        #expect(output.frameLength == 800)
    }

    /// 無音ではなくサイン波を入れる。無音だと変換器が 0 フレームを返すことがあり、
    /// フレーム数の検証にならない。
    private static func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2.0 * Double.pi * 440.0 / format.sampleRate
        for channel in 0..<Int(format.channelCount) {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for i in 0..<Int(frames) {
                data[i] = Float(sin(Double(i) * step)) * 0.5
            }
        }
        return buffer
    }
}
