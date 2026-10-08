import AVFoundation
import Foundation

/// マイクとシステム音声を同時に、別トラックとして録音する。
///
/// オンライン会議では「マイク = 自分 / システム音声 = 相手」なので、
/// トラックを分けること自体が話者分離になる。混ぜた音声を後から
/// 分離するより正確で、追加のモデルも要らない。
///
/// 2 つの音源は別クロックで動くため、時刻は両者が持つホスト時刻を
/// 共通の基準に射影する。サンプル数で数えると長時間でずれていく。
public final class DualTrackRecorder: @unchecked Sendable {

    /// ASR に流す 16kHz mono バッファ。
    /// `offset` は録音開始からの秒数（共通タイムライン上の値）。
    public var onASRBuffer: ((AVAudioPCMBuffer, TrackKind, TimeInterval) -> Void)?

    /// 波形表示用の入力レベル。メインスレッドで呼ぶ。
    public var onLevel: ((Float, TrackKind) -> Void)?

    /// 録音中のエラー。片方のトラックが倒れても録音自体は続ける。
    public var onError: ((Error, TrackKind) -> Void)?

    public private(set) var isRecording = false
    /// 実際に録れているトラック。システム音声が使えない場合はマイクのみになる。
    public private(set) var activeTracks: [TrackKind] = []

    private let mic = MicRecorder()
    private let systemTap = SystemAudioTap()
    private var systemWriter: TrackWriter?
    private var startHostTime: UInt64 = 0

    public init() {}

    // MARK: - 制御

    /// 録音の準備をして、実際に録れるトラックを返す。音声はまだ流れない。
    ///
    /// `captureSystemAudio` が true でもシステム音声の準備に失敗した場合は、
    /// マイクだけで続ける。会議の記録を丸ごと失う方が損失が大きいため、
    /// ここでは失敗を致命的とせず `onError` で知らせるにとどめる。
    @discardableResult
    public func prepare(
        paths: StoragePaths,
        recordingID: String,
        captureSystemAudio: Bool
    ) throws -> [TrackKind] {
        guard !isRecording else { throw MicRecorderError.alreadyRecording }

        activeTracks = []

        mic.onLevel = { [weak self] level in self?.onLevel?(level, .mic) }
        mic.onError = { [weak self] error in self?.onError?(error, .mic) }
        mic.onASRBuffer = { [weak self] buffer, hostTime in
            guard let self else { return }
            self.onASRBuffer?(buffer, .mic, self.offset(for: hostTime))
        }

        try mic.prepare(
            storageURL: paths.audioFile(recordingID, track: .mic),
            asrURL: paths.asrAudioFile(recordingID, track: .mic))
        activeTracks.append(.mic)

        guard captureSystemAudio else { return activeTracks }

        do {
            try prepareSystemAudio(paths: paths, recordingID: recordingID)
            activeTracks.append(.system)
        } catch {
            onError?(error, .system)
        }
        return activeTracks
    }

    /// 準備済みのトラックを、できるだけ同時に走らせる。
    public func start() throws {
        guard !isRecording else { return }

        startHostTime = HostTime.now()
        try mic.start()
        if activeTracks.contains(.system) {
            do {
                try systemTap.start()
            } catch {
                // マイクだけで続行する
                onError?(error, .system)
                activeTracks.removeAll { $0 == .system }
            }
        }
        isRecording = true
    }

    @discardableResult
    public func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false

        let duration = mic.stop()

        systemTap.stop()
        systemWriter?.close()
        systemWriter = nil

        return duration
    }

    // MARK: - システム音声

    private func prepareSystemAudio(paths: StoragePaths, recordingID: String) throws {
        try systemTap.prepare()
        guard let format = systemTap.format else {
            throw SystemAudioTapError.unexpectedFormat("形式を取得できませんでした")
        }

        let writer = try TrackWriter(
            storageURL: paths.audioFile(recordingID, track: .system),
            asrURL: paths.asrAudioFile(recordingID, track: .system),
            sourceFormat: format)
        systemWriter = writer

        systemTap.onError = { [weak self] error in self?.onError?(error, .system) }
        systemTap.onBuffer = { [weak self] buffer, hostTime in
            guard let self else { return }
            do {
                if let resampled = try self.systemWriter?.write(buffer) {
                    self.onASRBuffer?(resampled, .system, self.offset(for: hostTime))
                }
            } catch {
                self.onError?(error, .system)
            }

            let level = MicRecorder.normalizedLevel(of: buffer)
            if let onLevel = self.onLevel {
                DispatchQueue.main.async { onLevel(level, .system) }
            }
        }
    }

    private func offset(for hostTime: UInt64) -> TimeInterval {
        HostTime.seconds(from: startHostTime, to: hostTime)
    }
}
