import AVFoundation
import Foundation
import os

public enum MicRecorderError: LocalizedError {
    case permissionDenied
    case noInputDevice
    case alreadyRecording
    case engineStartFailed(String)
    case fileCreationFailed(String)
    case formatMismatch(label: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: MicPermission.deniedGuidance
        case .noInputDevice: "マイクが見つかりません。入力デバイスを確認してください。"
        case .alreadyRecording: "すでに録音中です"
        case .engineStartFailed(let d): "録音を開始できませんでした: \(d)"
        case .fileCreationFailed(let d): "録音ファイルを作成できませんでした: \(d)"
        case .formatMismatch(let label, let expected, let actual):
            "音声形式が一致しません (\(label)): 期待 \(expected) / 実際 \(actual)"
        }
    }
}

/// マイク入力を録音する。
///
/// 保管用の m4a と ASR 用の 16kHz mono WAV を同時に書き、
/// 変換済みバッファは `onASRBuffer` にも流す。
/// バッファにはホスト時刻を添えるので、システム音声トラックと
/// 共通のタイムライン上で突き合わせられる。
public final class MicRecorder: @unchecked Sendable {

    // MARK: - コールバック

    /// 0...1 に正規化した入力レベル。波形表示用。メインスレッドで呼ぶ。
    public var onLevel: ((Float) -> Void)?

    /// 16kHz mono に変換済みのバッファとホスト時刻。
    /// オーディオスレッドで呼ばれるので、重い処理をここに置かないこと。
    public var onASRBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    /// 録音中に起きたエラー。握り潰さず UI に出すために通知する。メインスレッドで呼ぶ。
    public var onError: ((Error) -> Void)?

    // MARK: - 状態

    public private(set) var isRecording = false

    /// 一時停止中か。オーディオスレッドからも読むのでロックで守る。
    public var isPaused: Bool { pausedFlag.withLock { $0 } }
    private let pausedFlag = OSAllocatedUnfairLock(initialState: false)

    private let engine = AVAudioEngine()
    private var writer: TrackWriter?

    public init() {}

    // MARK: - 制御

    /// 録音の準備をする。ファイルとタップを用意するが、音声はまだ流れない。
    ///
    /// システム音声トラックの準備には 1 秒近くかかる。マイクを先に走らせて
    /// しまうとその間の音声がマイクにだけ入り、2 トラックの長さが揃わない。
    /// 準備と開始を分けているのはそのため。
    public func prepare(storageURL: URL, asrURL: URL) throws {
        guard !isRecording else { throw MicRecorderError.alreadyRecording }
        guard MicPermission.status == .granted else { throw MicRecorderError.permissionDenied }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicRecorderError.noInputDevice
        }

        let writer = try TrackWriter(
            storageURL: storageURL, asrURL: asrURL, sourceFormat: inputFormat)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.handle(buffer, hostTime: time.hostTime)
        }

        engine.prepare()
    }

    /// 取り込みを開始する。`prepare` 済みであること。
    public func start() throws {
        guard !isRecording, writer != nil else { return }
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            writer?.close()
            writer = nil
            throw MicRecorderError.engineStartFailed(error.localizedDescription)
        }
        isRecording = true
    }

    /// 一時停止する。入力デバイスも止めるので、メニューバーのマイク表示も消える。
    ///
    /// 止めている間のバッファは書かずに捨てる。ファイルも文字起こしも
    /// 「録っていた区間だけ」を詰めてつなぐので、両者の時刻はずれない。
    public func pause() {
        guard isRecording, !isPaused else { return }
        pausedFlag.withLock { $0 = true }
        engine.pause()
    }

    /// 一時停止から再開する。
    public func resume() throws {
        guard isRecording, isPaused else { return }
        do {
            try engine.start()
        } catch {
            throw MicRecorderError.engineStartFailed(error.localizedDescription)
        }
        pausedFlag.withLock { $0 = false }
    }

    /// 録音を止めて、録音した長さ (秒) を返す。
    /// 実際に書き込んだフレーム数から算出するので、UI のタイマーより正確。
    @discardableResult
    public func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let duration = writer?.duration ?? 0
        writer?.close()
        writer = nil
        pausedFlag.withLock { $0 = false }
        return duration
    }

    // MARK: - 内部

    private func handle(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard isRecording, !isPaused else { return }

        do {
            if let resampled = try writer?.write(buffer) {
                onASRBuffer?(resampled, hostTime)
            }
        } catch {
            report(error)
        }

        let level = Self.normalizedLevel(of: buffer)
        if let onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    private func report(_ error: Error) {
        guard let onError else { return }
        DispatchQueue.main.async { onError(error) }
    }

    /// RMS を dB に直し、-60dB…0dB を 0…1 に写す。
    /// 生の RMS をそのまま使うと、通常の話し声では波形がほとんど動かない。
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        guard rms > 0 else { return 0 }

        let db = 20 * log10(rms)
        let floorDB: Float = -60
        return ((db - floorDB) / -floorDB).clamped(to: 0...1)
    }
}
