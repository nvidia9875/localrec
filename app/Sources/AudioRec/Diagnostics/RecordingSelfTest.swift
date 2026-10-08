import AudioRecKit
import AVFoundation
import Foundation

/// 実際にマイクから録音して、ファイルが期待どおり書けるかを確かめる。
///
/// マイクの TCC 許可は署名済み .app に紐づくので、この検証はアプリの
/// プロセス内で走らせる必要がある (ターミナルから叩いても別アプリ扱いになる)。
///
/// 使い方:
///   AudioRec.app/Contents/MacOS/AudioRec --selftest [秒数]
@MainActor
enum RecordingSelfTest {

    static func requestedDuration(_ arguments: [String] = CommandLine.arguments) -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--selftest") else { return nil }
        let next = index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
        return next ?? 3.0
    }

    /// `--out <path>` があればレポートの書き出し先を返す。
    ///
    /// `open -a` から起動すると標準出力が捨てられるが、TCC のダイアログを
    /// AudioRec 自身に帰属させるにはその起動方法が要る。そこで結果はファイルにも残す。
    static func requestedReportPath(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// 検証を実行する。すべて通れば true。
    static func run(
        duration: TimeInterval, reportPath: URL?, playbackFile: URL? = nil
    ) async -> Bool {
        // パイプに繋ぐと stdout がブロックバッファになり、権限ダイアログ待ちの間
        // 何も表示されなくなる。行バッファにして進捗が見えるようにする。
        setvbuf(stdout, nil, _IOLBF, 0)

        var ok = true
        var report: [String] = []

        func emit(_ line: String) {
            print(line)
            report.append(line)
            if let reportPath {
                try? Data((report.joined(separator: "\n") + "\n").utf8).write(to: reportPath)
            }
        }
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            emit("\(condition ? "  ✔" : "  ✘") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { ok = false }
        }

        emit("録音の自己診断 (\(Int(duration)) 秒)")

        // 一時ディレクトリを使い、ユーザーの録音一覧を汚さない
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audiorec-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(paths: StoragePaths(root: root))
        let session = RecordingSession(store: store)

        emit("\n[1/3] マイクの権限")
        let permission = await MicPermission.request()
        check("許可されている", permission == .granted, permission == .granted ? "" : "\(permission)")
        guard permission == .granted else {
            emit("\n" + MicPermission.deniedGuidance)
            return false
        }

        emit("\n[2/3] 録音")
        // システム音声トラックの検証用に、テスト中は音を鳴らしておく。
        // 無音のままだとトラックが作られても中身が空で、成否が判別できない。
        var player: AVAudioPlayer?
        if let playbackFile {
            player = try? AVAudioPlayer(contentsOf: playbackFile)
            player?.numberOfLoops = -1
            player?.volume = 0.5
            player?.play()
        }
        let meta: RecordingMeta
        do {
            meta = try await session.start(title: "自己診断")
        } catch {
            check("録音を開始できた", false, error.localizedDescription)
            return false
        }
        check("録音を開始できた", true)

        try? await Task.sleep(for: .seconds(duration))
        check("入力レベルを受け取れた", !session.levels.isEmpty, "\(session.levels.count) サンプル")

        let tracks = session.activeTracks
        emit("  トラック: \(tracks.map(\.rawValue).joined(separator: ", "))")
        player?.stop()

        let stopped: RecordingMeta?
        do {
            stopped = try await session.stop()
        } catch {
            check("録音を停止できた", false, error.localizedDescription)
            return false
        }
        check("録音を停止できた", stopped != nil)

        emit("\n[3/3] 出力ファイル")
        let recorded = stopped?.duration ?? 0
        // 実測の長さが指定の ±25% に収まっていること
        check("長さが妥当", abs(recorded - duration) < duration * 0.25,
              String(format: "%.2f 秒 (指定 %.0f 秒)", recorded, duration))

        let m4a = store.paths.audioFile(meta.id, track: .mic)
        let wav = store.paths.asrAudioFile(meta.id, track: .mic)
        check("m4a が書けている", size(of: m4a) > 1_000, "\(size(of: m4a)) バイト")
        check("wav が書けている", size(of: wav) > 1_000, "\(size(of: wav)) バイト")

        if tracks.contains(.system) {
            let systemM4A = store.paths.audioFile(meta.id, track: .system)
            let systemWAV = store.paths.asrAudioFile(meta.id, track: .system)
            check("システム音声の m4a が書けている", size(of: systemM4A) > 1_000,
                  "\(size(of: systemM4A)) バイト")
            check("システム音声の wav が書けている", size(of: systemWAV) > 1_000,
                  "\(size(of: systemWAV)) バイト")

            // 2 トラックの長さが揃っていること。ずれていると話者ラベルと発言が食い違う。
            if let micFile = try? AVAudioFile(forReading: wav),
               let systemFile = try? AVAudioFile(forReading: systemWAV) {
                let micSeconds = Double(micFile.length) / micFile.processingFormat.sampleRate
                let systemSeconds = Double(systemFile.length) / systemFile.processingFormat.sampleRate
                check("2 トラックの長さが揃っている", abs(micSeconds - systemSeconds) < 0.5,
                      String(format: "マイク %.2f 秒 / システム %.2f 秒", micSeconds, systemSeconds))
            }
        } else {
            emit("  （システム音声トラックなし）")
        }

        // 16kHz mono に変換されているか。ASR の入力要件そのもの。
        if let file = try? AVAudioFile(forReading: wav) {
            let format = file.processingFormat
            check("wav が 16kHz", format.sampleRate == 16_000, "\(Int(format.sampleRate)) Hz")
            check("wav がモノラル", format.channelCount == 1, "\(format.channelCount) ch")

            let wavDuration = Double(file.length) / format.sampleRate
            check("wav の長さが録音長と一致", abs(wavDuration - recorded) < 0.5,
                  String(format: "%.2f 秒", wavDuration))
        } else {
            check("wav を読み込める", false)
        }

        emit("\n\(ok ? "すべて通過しました" : "失敗した項目があります")")
        return ok
    }

    private static func size(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int ?? 0
    }
}
