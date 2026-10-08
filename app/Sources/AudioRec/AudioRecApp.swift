import AudioRecKit
import SwiftUI

@main
struct AudioRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unifiedCompact)
    }
}

/// SwiftPM で組んだ .app は Dock からの起動時に前面化しないことがあるため、
/// 明示的に activation policy を設定する。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // --snapshot <dir> が渡されていれば UI を PNG に書き出して終了する。
        // 画面収録の権限が要らない視覚確認・視覚回帰の手段。
        if let directory = SnapshotRunner.requestedOutputDirectory() {
            runSnapshotsAndExit(to: directory)
            return
        }

        // --selftest [秒数] で実際にマイクから録れるかを確認して終了する。
        // マイクの TCC 許可はこの .app に紐づくため、アプリ内で走らせる必要がある。
        if let duration = RecordingSelfTest.requestedDuration() {
            // .accessory のままだとマイク許可ダイアログが前面に出てこず、
            // ユーザーが気づけないまま待ち続けることになる。
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                let ok = await RecordingSelfTest.run(
                    duration: duration, reportPath: RecordingSelfTest.requestedReportPath(),
                    playbackFile: SystemAudioSelfTest.requestedPlaybackFile())
                exit(ok ? 0 : 1)
            }
            return
        }

        // --systemtest [秒数] でシステム音声キャプチャを確認する。
        // 画面収録/システムオーディオ録音の許可ダイアログが出るので前面化する。
        if let duration = SystemAudioSelfTest.requestedDuration() {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let playback = SystemAudioSelfTest.requestedPlaybackFile()
            Task {
                let ok = await SystemAudioSelfTest.run(
                    duration: duration, playbackFile: playback,
                    reportPath: SystemAudioSelfTest.requestedReportPath())
                exit(ok ? 0 : 1)
            }
            return
        }

        // --postprocesstest で claude -p による整形と要約を実際に呼んで確かめる。
        if PostprocessSelfTest.isRequested() {
            NSApp.setActivationPolicy(.accessory)
            let model = ASRSelfTest.requestedModel() ?? "sonnet"
            Task {
                let ok = await PostprocessSelfTest.run(model: model)
                exit(ok ? 0 : 1)
            }
            return
        }

        // --titletest でタイトル変更が保存され一覧に映るかを確かめる。
        if TitleSelfTest.isRequested() {
            NSApp.setActivationPolicy(.accessory)
            Task {
                let ok = await TitleSelfTest.run(
                    outputDirectory: TitleSelfTest.requestedOutputDirectory())
                exit(ok ? 0 : 1)
            }
            return
        }

        // --summarytest [録音ID] で、保存済みの録音を実寸のまま要約して確かめる。
        if SummarySelfTest.isRequested() {
            NSApp.setActivationPolicy(.accessory)
            let model = ASRSelfTest.requestedModel() ?? "sonnet"
            Task {
                let ok = await SummarySelfTest.run(
                    id: SummarySelfTest.requestedID(), model: model,
                    save: SummarySelfTest.shouldSave())
                exit(ok ? 0 : 1)
            }
            return
        }

        // --batch <manifest> でまとめて評価する (CER / RTF 測定)。
        if let manifest = BatchBench.requestedManifest() {
            NSApp.setActivationPolicy(.accessory)
            let output = BatchBench.requestedOutput()
            let glossary = ASRSelfTest.requestedGlossary()
            Task {
                let ok = await BatchBench.run(
                    manifest: manifest, output: output, glossary: glossary)
                exit(ok ? 0 : 1)
            }
            return
        }

        // --score <hypotheses> で外部エンジンの結果を採点する。
        if let input = BatchBench.requestedScoreInput() {
            NSApp.setActivationPolicy(.accessory)
            let output = BatchBench.requestedOutput()
            let glossary = ASRSelfTest.requestedGlossary()
            let ok = BatchBench.score(input: input, output: output, glossary: glossary)
            exit(ok ? 0 : 1)
        }

        // --livetest <file> でライブ経路 (startLive/feed/finishLive) を検証する。
        if let file = ASRSelfTest.requestedLiveFile() {
            NSApp.setActivationPolicy(.accessory)
            let reference = ASRSelfTest.requestedReference()
            let glossary = ASRSelfTest.requestedGlossary()
            Task {
                let ok = await ASRSelfTest.runLive(
                    file: file, reference: reference, glossary: glossary,
                    engineKind: ASRSelfTest.requestedEngine(),
                    model: ASRSelfTest.requestedModel())
                exit(ok ? 0 : 1)
            }
            return
        }

        // --asrtest <file> で音声ファイルを文字起こしして終了する。
        if let file = ASRSelfTest.requestedFile() {
            NSApp.setActivationPolicy(.accessory)
            let jsonPath = ASRSelfTest.requestedJSONPath()
            let reference = ASRSelfTest.requestedReference()
            let glossary = ASRSelfTest.requestedGlossary()
            Task {
                let ok = await ASRSelfTest.run(
                    file: file, jsonPath: jsonPath, reference: reference, glossary: glossary,
                    engineKind: ASRSelfTest.requestedEngine(),
                    model: ASRSelfTest.requestedModel())
                exit(ok ? 0 : 1)
            }
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runSnapshotsAndExit(to directory: URL) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let count = try SnapshotRunner.run(outputDirectory: directory)
            print("スナップショットを \(count) 枚書き出しました: \(directory.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
