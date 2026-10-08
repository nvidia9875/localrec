import AudioRecKit
import AVFoundation
import Foundation

/// システム音声のキャプチャが動くかを確かめる。
///
/// 検証中に音が鳴っていないと無音しか録れないので、テスト自身が
/// 音声ファイルを再生してから録る。
///
/// 使い方:
///   AudioRec --systemtest [秒数] [--play <音声ファイル>]
@MainActor
enum SystemAudioSelfTest {

    static func requestedDuration(_ arguments: [String] = CommandLine.arguments) -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--systemtest") else { return nil }
        let next = index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
        return next ?? 5.0
    }

    static func requestedPlaybackFile(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--play"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    /// `--out <path>` があればレポートの書き出し先を返す。
    /// `open -a` から起動すると標準出力が捨てられるが、TCC のダイアログを
    /// AudioRec 自身に帰属させるにはその起動方法が要る。
    static func requestedReportPath(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(duration: TimeInterval, playbackFile: URL?, reportPath: URL? = nil) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        var ok = true
        var report: [String] = []

        func print(_ line: String) {
            Swift.print(line)
            report.append(line)
            if let reportPath {
                try? Data((report.joined(separator: "\n") + "\n").utf8).write(to: reportPath)
            }
        }
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "  ✔" : "  ✘") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { ok = false }
        }

        print("システム音声キャプチャの診断 (\(Int(duration)) 秒)")

        let tap = SystemAudioTap()
        // オーディオスレッドから触るのでロックで守る
        let counter = BufferCounter()
        tap.onBuffer = { buffer, hostTime in
            counter.record(buffer: buffer, hostTime: hostTime)
        }
        tap.onError = { error in
            print("  エラー: \(error.localizedDescription)")
        }
        tap.onFirstBufferLayout = { layout in
            let described = layout.map { "\($0.channels)ch/\($0.bytes)B" }.joined(separator: ", ")
            print("  入力ストリーム構成: [\(described)]")
        }

        print("\n[1/3] タップの作成")
        do {
            try tap.start()
        } catch {
            check("開始できた", false, error.localizedDescription)
            print("\n" + (error.localizedDescription))
            return false
        }
        defer { tap.stop() }

        check("開始できた", true)
        if let format = tap.format {
            print("  形式: \(Int(format.sampleRate))Hz \(format.channelCount)ch")
        }

        print("\n[2/3] 音声の再生と取り込み")
        var player: AVAudioPlayer?
        if let playbackFile {
            player = try? AVAudioPlayer(contentsOf: playbackFile)
            player?.numberOfLoops = -1
            player?.volume = 0.6
            player?.play()
            check("テスト音声を再生できた", player?.isPlaying == true, playbackFile.lastPathComponent)
        } else {
            print("  （--play が無いので、この間に何か音を鳴らしてください）")
        }

        try? await Task.sleep(for: .seconds(duration))
        player?.stop()

        print("\n[3/3] 結果")
        let snapshot = counter.snapshot()
        check("バッファを受け取れた", snapshot.buffers > 0, "\(snapshot.buffers) 個")
        check("フレームを受け取れた", snapshot.frames > 0, "\(snapshot.frames) フレーム")

        // 再生していたのに無音なら、タップが実際の音を拾えていない
        if playbackFile != nil {
            check("音が入っている", snapshot.peak > 0.001, String(format: "ピーク %.4f", snapshot.peak))
        } else {
            print("  ピーク: \(String(format: "%.4f", snapshot.peak))")
        }

        check("ホスト時刻が進んでいる", snapshot.lastHostTime > snapshot.firstHostTime,
              "\(snapshot.firstHostTime) → \(snapshot.lastHostTime)")

        print("\n\(ok ? "すべて通過しました" : "失敗した項目があります")")
        return ok
    }
}

/// オーディオスレッドから書き込まれるので、ロックで包む。
private final class BufferCounter: @unchecked Sendable {
    struct Snapshot {
        var buffers = 0
        var frames = 0
        var peak: Float = 0
        var firstHostTime: UInt64 = 0
        var lastHostTime: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = Snapshot()

    func record(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channel[index]))
            }
        }

        lock.lock()
        defer { lock.unlock() }
        if state.buffers == 0 { state.firstHostTime = hostTime }
        state.buffers += 1
        state.frames += Int(buffer.frameLength)
        state.peak = max(state.peak, peak)
        state.lastHostTime = hostTime
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
