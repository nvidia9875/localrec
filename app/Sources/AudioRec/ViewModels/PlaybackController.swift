import AVFoundation
import Foundation
import Observation

/// 録音した音声の再生。文字起こしの行と再生位置を同期させるために
/// `currentTime` を細かく更新する。
@MainActor
@Observable
final class PlaybackController: NSObject {

    /// 再生位置の更新間隔。文字起こし行のハイライトが滑らかに追従する程度に細かく。
    private static let tickInterval: TimeInterval = 0.05

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var loadedURL: URL?

    var rate: Float = 1.0 {
        didSet {
            player?.rate = rate
            if isPlaying { player?.play() }
        }
    }

    var onError: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    // MARK: - 読み込み

    /// 音声を読み込む。同じ URL なら何もしない。
    /// ファイルが無い場合はエラーにせず「再生できない状態」にとどめる
    /// (録音直後や WAV を消した後など、正常にあり得る状況のため)。
    func load(url: URL?) {
        guard loadedURL != url else { return }
        stop()

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            loadedURL = nil
            duration = 0
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            player.delegate = self
            self.player = player
            loadedURL = url
            duration = player.duration
            currentTime = 0
        } catch {
            player = nil
            loadedURL = nil
            duration = 0
            onError?("音声を再生できませんでした: \(error.localizedDescription)")
        }
    }

    // MARK: - 操作

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = time.clamped(to: 0...max(0, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// 15 秒送り / 戻し。
    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    // MARK: - 内部

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTimer()
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
