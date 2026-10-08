import AVFoundation
import Foundation
import os

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

    /// 一時停止中か。システム音声のコールバックからも読むのでロックで守る。
    public var isPaused: Bool { pausedFlag.withLock { $0 } }
    private let pausedFlag = OSAllocatedUnfairLock(initialState: false)

    private let mic = MicRecorder()
    private let systemTap = SystemAudioTap()
    private var systemWriter: TrackWriter?
    private var startHostTime: UInt64 = 0

    public init() {}

    // MARK: - 制御

    /// 録音の準備をして、実際に録れるトラックを返す。音声はまだ流れない。
    ///
    /// `appending` が true なら、既存の録音の続きとして `audio/.pending_*` に書く。
    /// m4a には追記できないので、本体へは停止後に `AudioAppender` でつなぐ。
    ///
    /// `captureSystemAudio` が true でもシステム音声の準備に失敗した場合は、
    /// マイクだけで続ける。会議の記録を丸ごと失う方が損失が大きいため、
    /// ここでは失敗を致命的とせず `onError` で知らせるにとどめる。
    @discardableResult
    public func prepare(
        paths: StoragePaths,
        recordingID: String,
        captureSystemAudio: Bool,
        appending: Bool = false
    ) throws -> [TrackKind] {
        guard !isRecording else { throw MicRecorderError.alreadyRecording }

        activeTracks = []
        let files = Destination(paths: paths, recordingID: recordingID, appending: appending)

        mic.onLevel = { [weak self] level in self?.onLevel?(level, .mic) }
        mic.onError = { [weak self] error in self?.onError?(error, .mic) }
        mic.onASRBuffer = { [weak self] buffer, hostTime in
            guard let self else { return }
            self.onASRBuffer?(buffer, .mic, self.offset(for: hostTime))
        }

        try mic.prepare(
            storageURL: files.storage(.mic),
            asrURL: files.asr(.mic))
        activeTracks.append(.mic)

        guard captureSystemAudio else { return activeTracks }

        do {
            try prepareSystemAudio(files: files)
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

    /// 一時停止する。止めている間の音声はどのトラックにも書かない。
    public func pause() {
        guard isRecording, !isPaused else { return }
        pausedFlag.withLock { $0 = true }
        mic.pause()
    }

    /// 一時停止から再開する。
    public func resume() throws {
        guard isRecording, isPaused else { return }
        try mic.resume()
        pausedFlag.withLock { $0 = false }
    }

    @discardableResult
    public func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false
        pausedFlag.withLock { $0 = false }

        let duration = mic.stop()

        systemTap.stop()
        systemWriter?.close()
        systemWriter = nil

        return duration
    }

    // MARK: - システム音声

    private func prepareSystemAudio(files: Destination) throws {
        try systemTap.prepare()
        guard let format = systemTap.format else {
            throw SystemAudioTapError.unexpectedFormat("形式を取得できませんでした")
        }

        let writer = try TrackWriter(
            storageURL: files.storage(.system),
            asrURL: files.asr(.system),
            sourceFormat: format)
        systemWriter = writer

        systemTap.onError = { [weak self] error in self?.onError?(error, .system) }
        systemTap.onBuffer = { [weak self] buffer, hostTime in
            // システム音声のタップは止めずに流し続け、一時停止中はここで捨てる
            guard let self, !self.isPaused else { return }
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

/// 書き込み先。新しい録音なら本体へ、続きなら `.pending_*` へ書く。
private struct Destination {
    let paths: StoragePaths
    let recordingID: String
    let appending: Bool

    func storage(_ track: TrackKind) -> URL {
        appending
            ? paths.pendingAudioFile(recordingID, track: track)
            : paths.audioFile(recordingID, track: track)
    }

    func asr(_ track: TrackKind) -> URL {
        appending
            ? paths.pendingASRAudioFile(recordingID, track: track)
            : paths.asrAudioFile(recordingID, track: track)
    }
}
