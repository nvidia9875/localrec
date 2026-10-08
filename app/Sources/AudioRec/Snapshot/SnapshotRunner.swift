import AppKit
import AudioRecKit
import SwiftUI

/// UI を PNG に書き出す。
///
/// `screencapture` は画面収録の TCC 権限を要求するが、アプリが自分の
/// SwiftUI ツリーを `ImageRenderer` で描く分には権限が要らない。
/// 視覚回帰テストの土台としても使う。
///
/// 使い方:
///   AudioRec.app/Contents/MacOS/AudioRec --snapshot <出力ディレクトリ>
@MainActor
enum SnapshotRunner {

    /// レスポンシブ確認用の幅。ウェブ側のブレークポイント運用に合わせている。
    private static let sizes: [(name: String, size: CGSize)] = [
        ("820x560", CGSize(width: 820, height: 560)),
        ("1120x760", CGSize(width: 1120, height: 760)),
        ("1440x900", CGSize(width: 1440, height: 900)),
    ]

    /// コマンドライン引数に `--snapshot <dir>` があれば出力先を返す。
    static func requestedOutputDirectory(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--snapshot"),
              index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    /// 全パターンを書き出す。書けた枚数を返す。
    @discardableResult
    static func run(outputDirectory: URL) throws -> Int {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        var written = 0
        for (sizeName, size) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"

                try write(
                    view: scene(state: .transcript, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("transcript_\(sizeName)_\(suffix).png"))
                written += 1

                // 録音中と空状態は最小幅でだけ確認すれば足りる
                guard sizeName == sizes[1].name else { continue }

                try write(
                    view: scene(state: .recording, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("recording_\(sizeName)_\(suffix).png"))
                written += 1

                try write(
                    view: scene(state: .empty, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("empty_\(sizeName)_\(suffix).png"))
                written += 1

                try write(
                    view: scene(state: .summary, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("summary_\(sizeName)_\(suffix).png"))
                written += 1

                try write(
                    view: scene(state: .memo, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("memo_\(sizeName)_\(suffix).png"))
                written += 1

                try write(
                    view: scene(state: .search, size: size),
                    scheme: scheme, size: size,
                    to: outputDirectory.appendingPathComponent("search_\(sizeName)_\(suffix).png"))
                written += 1
            }
        }
        return written
    }

    // MARK: - 描画

    /// SwiftUI ツリーを実際の NSWindow にホストして描画し、PNG に落とす。
    ///
    /// `ImageRenderer` は使えない。ScrollView / LazyVStack が実体化せず本文が空になり、
    /// TextField・Slider・Menu といった AppKit 由来のコントロールは
    /// 「描画できません」の黄色い矩形に化けるため。
    /// 実ウィンドウならレイアウトが本番と同じ経路を通る。
    /// 画面の中身を読むわけではないので画面収録の権限は要らない。
    private static func write(
        view: some View, scheme: ColorScheme, size: CGSize, to url: URL
    ) throws {
        let (window, hosting) = host(view: view, scheme: scheme, size: size)
        defer { window.close() }

        settle(hosting)
        try capture(hosting, name: url.lastPathComponent).write(to: url)
    }

    /// 画面外の実ウィンドウに SwiftUI ツリーを載せる。
    static func host(
        view: some View, scheme: ColorScheme, size: CGSize
    ) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let hosting = NSHostingView(
            rootView: AnyView(
                view
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
            )
        )
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // NSColor の dynamic provider はウィンドウの appearance を見て解決される。
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // 画面外に置いたまま order front する。ウィンドウサーバに載せないと
        // レイヤーが描画されず、真っ白な画像になる。
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        return (window, hosting)
    }

    /// 今描かれているものを PNG にする。
    static func capture(_ hosting: NSView, name: String) throws -> Data {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.renderFailed(name)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        return png
    }

    /// SwiftUI がレイアウトと非同期の描画を終えるまでランループを回す。
    /// これを省くと ScrollView の中身が空のまま撮れることがある。
    static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    // MARK: - 対象の画面

    private enum SceneState {
        case transcript
        case memo
        case summary
        case search
        case recording
        case empty
    }

    private static func scene(state: SceneState, size: CGSize) -> some View {
        let model = SnapshotFixtures.makeModel()

        switch state {
        case .transcript:
            break
        case .memo:
            model.detailTab = .memo
            model.memoDraft = SnapshotFixtures.memo
        case .summary:
            model.detailTab = .summary
            model.injectSummaryForSnapshot(SnapshotFixtures.summary)
        case .search:
            model.injectSearchForSnapshot(query: "音声", hits: SnapshotFixtures.searchHits())
        case .recording:
            model.injectFixture(
                recordings: SnapshotFixtures.metaList(),
                selected: SnapshotFixtures.emptyRecording())
        case .empty:
            model.injectFixture(recordings: [], selected: nil)
        }

        if state == .recording { model.injectRecordingForSnapshot() }
        return SnapshotScene(model: model, showRecordBar: state == .recording)
    }
}

/// `NavigationSplitView` は ImageRenderer では正しく描かれないため、
/// 同じ構成を素の HStack で組んで描画する。
private struct SnapshotScene: View {
    let model: AppModel
    let showRecordBar: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: Theme.Metrics.sidebarWidth)

            Rectangle().fill(Theme.Palette.rule).frame(width: 1)

            VStack(spacing: 0) {
                if showRecordBar {
                    SnapshotRecordBar(elapsed: 132, levels: Self.demoLevels)
                }
                if let recording = model.selectedRecording {
                    RecordingDetailView(model: model, recording: recording)
                } else {
                    SnapshotEmptyState()
                }
                if !showRecordBar {
                    PlayerBarView(playback: model.playback)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background)
        }
        .background(Theme.Palette.background)
    }

    /// 波形が動いて見えるよう、それらしい起伏を持つ固定値を使う。
    private static let demoLevels: [Float] = (0..<64).map { i in
        let base = sin(Double(i) * 0.35) * 0.35 + 0.45
        let jitter = sin(Double(i) * 1.7) * 0.18
        return Float(max(0.02, min(1.0, base + jitter)))
    }
}

/// 録音バーは AppModel の状態に依存するので、スナップショットでは値を直接渡す版を使う。
private struct SnapshotRecordBar: View {
    let elapsed: TimeInterval
    let levels: [Float]

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Theme.Palette.recording).frame(width: 8, height: 8)
            Text(TimeCode.short(elapsed))
                .font(Theme.Font.timestamp)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.text)
            WaveformView(levels: levels).frame(maxWidth: .infinity)
            HStack(spacing: 5) {
                Image(systemName: "pause.fill").font(.system(size: 9))
                Text("一時停止").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Theme.Palette.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 9))
                Text("停止").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Theme.Palette.recording)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 12)
        .background(Theme.Palette.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Palette.rule).frame(height: 1)
        }
    }
}

private struct SnapshotEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text("録音を選ぶか、「新規」で作ってください")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)
            Text("⌘N で新規作成。録音は開いた先で ⌘R")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SnapshotError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let name): "スナップショットを描画できませんでした: \(name)"
        }
    }
}
