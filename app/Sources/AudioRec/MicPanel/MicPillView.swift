import AppKit
import AudioRecKit
import SwiftUI

/// 常時表示のマイクパネルの中身。Notion の会議ノートが録音中に出す浮遊ピルに寄せている。
///
/// AppModel から状態を読み、見た目は `MicPillContent` に任せる。
/// スナップショットでは `MicPillContent` に値を直接渡して描く。
struct MicPillView: View {
    let model: AppModel
    let environment: MicEnvironment
    let onOpenMain: () -> Void

    var body: some View {
        MicPillContent(
            status: status,
            elapsed: model.session.elapsed,
            levels: model.session.levels,
            deviceName: environment.deviceName,
            actions: actions
        )
        .onHover { hovering in
            // システム設定で許可を変えて戻ってきたときに、押す前から表示を合わせる
            if hovering { environment.refreshPermission() }
        }
    }

    private var status: MicStatus {
        MicStatus.derive(
            permission: environment.permission,
            hasInputDevice: environment.deviceName != nil,
            isRecording: model.session.isRecording,
            isPaused: model.session.isPaused,
            isSaving: model.session.isSaving,
            downloadProgress: model.session.modelDownloadProgress)
    }

    private var actions: MicPillActions {
        MicPillActions(
            start: {
                Task {
                    await model.startNewRecording()
                    environment.refreshPermission()
                    // 失敗の知らせは本体のウインドウに出る。後ろに隠れたままにしない
                    if model.errorMessage != nil { onOpenMain() }
                }
            },
            togglePause: {
                model.togglePause()
                if model.errorMessage != nil { onOpenMain() }
            },
            stop: {
                Task {
                    await model.stopRecording()
                    if model.errorMessage != nil { onOpenMain() }
                }
            },
            openMain: onOpenMain,
            openPrivacySettings: MicEnvironment.openPrivacySettings
        )
    }
}

/// パネルのボタンが呼ぶ操作。見た目からモデルを切り離すために束ねる。
struct MicPillActions {
    var start: () -> Void = {}
    var togglePause: () -> Void = {}
    var stop: () -> Void = {}
    var openMain: () -> Void = {}
    var openPrivacySettings: () -> Void = {}
}

// MARK: - 見た目

struct MicPillContent: View {
    let status: MicStatus
    let elapsed: TimeInterval
    let levels: [Float]
    let deviceName: String?
    var actions = MicPillActions()

    enum Metrics {
        static let width: CGFloat = 300
        static let height: CGFloat = 44
        /// 影を切らずに描くための、ピルの外側の余白。パネルはこの分だけ大きく取る。
        static let shadowMargin: CGFloat = 14
        static let badgeSize: CGFloat = 30
        static let waveformBars = 22
    }

    var body: some View {
        HStack(spacing: 10) {
            // ボタン以外のところをつかんでパネルを動かせる
            HStack(spacing: 10) {
                MicBadge(status: status)
                statusLabel
                Spacer(minLength: 0)
            }
            .overlay(WindowDragHandle())

            controls
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(width: Metrics.width, height: Metrics.height)
        // ボタンの間や縁もつかめるよう、ピル全体の背面にも置く
        .background(WindowDragHandle().clipShape(Capsule()))
        .background(Theme.Palette.background, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .padding(Metrics.shadowMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("マイク: \(statusTitle)")
    }

    // MARK: 状態の文言

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .recording:
            HStack(spacing: 8) {
                elapsedText
                WaveformView(levels: levels, barCount: Metrics.waveformBars)
                    .frame(maxWidth: .infinity)
            }
        case .paused:
            twoLine(title: statusTitle, detail: TimeCode.short(elapsed), monospacedDetail: true)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                title(statusTitle)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                title("音声認識モデルを取得中 \(Int(progress * 100))%").monospacedDigit()
                ProgressView(value: progress).controlSize(.mini)
            }
        case .idle:
            twoLine(title: statusTitle, detail: deviceName ?? "")
        case .permissionDenied:
            twoLine(title: statusTitle, detail: "設定で許可してください")
        case .noInputDevice:
            twoLine(title: statusTitle, detail: "入力デバイスをつないでください")
        }
    }

    private var statusTitle: String {
        switch status {
        case .idle: "待機中"
        case .recording: "録音中"
        case .paused: "一時停止中"
        case .saving: "保存しています…"
        case .downloading: "音声認識モデルを取得中"
        case .permissionDenied: "マイク未許可"
        case .noInputDevice: "マイクが見つかりません"
        }
    }

    private var elapsedText: some View {
        Text(TimeCode.short(elapsed))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.text)
            .fixedSize()
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.text)
            .lineLimit(1)
    }

    private func twoLine(title text: String, detail: String, monospacedDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title(text)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: monospacedDetail ? .monospaced : .default))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: 操作

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch status {
            case .idle:
                RecordButton(action: actions.start)
            case .recording, .paused:
                PillIconButton(
                    systemName: status == .paused ? "record.circle" : "pause.fill",
                    help: status == .paused ? "録音を再開" : "録音を一時停止",
                    action: actions.togglePause)
                PillIconButton(
                    systemName: "stop.fill", help: "録音を停止", role: .destructive,
                    action: actions.stop)
            case .permissionDenied:
                PillTextButton(title: "設定を開く", action: actions.openPrivacySettings)
            case .saving, .downloading, .noInputDevice:
                EmptyView()
            }
            PillIconButton(
                systemName: "arrow.up.forward.app", help: "AudioRec を開く",
                action: actions.openMain)
        }
    }
}

// MARK: - 部品

/// 左端の丸いマイク。録っている間だけ赤く、外側の輪が入力の大きさで膨らむ。
private struct MicBadge: View {
    let status: MicStatus

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: MicPillContent.Metrics.badgeSize, height: MicPillContent.Metrics.badgeSize)
        .overlay {
            if status == .recording { PulseRing() }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .permissionDenied, .noInputDevice: "mic.slash.fill"
        case .paused: "pause.fill"
        default: "mic.fill"
        }
    }

    private var fill: Color {
        switch status {
        case .recording: Theme.Palette.recording
        case .permissionDenied, .noInputDevice: Theme.Palette.recording.opacity(0.12)
        default: Theme.Palette.surfaceHover
        }
    }

    private var foreground: Color {
        switch status {
        case .recording: .white
        case .permissionDenied, .noInputDevice: Theme.Palette.recording
        default: Theme.Palette.text
        }
    }
}

/// 録音中にバッジの外へ広がって消える輪。止めている間は出さない（録れていると誤解させない）。
private struct PulseRing: View {
    @State private var isExpanded = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Circle()
            .stroke(Theme.Palette.recording, lineWidth: 2)
            .scaleEffect(isExpanded ? 1.5 : 1.0)
            .opacity(isExpanded ? 0 : 0.6)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}

/// 待機中の主操作。赤い点と「録音」。
private struct RecordButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(Theme.Palette.recording).frame(width: 7, height: 7)
                Text("録音").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                isHovering ? Theme.Palette.surfaceSelected : Theme.Palette.surfaceHover,
                in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .help("新しい録音を始める")
    }
}

private struct PillTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    isHovering ? Theme.Palette.surfaceSelected : Theme.Palette.surfaceHover,
                    in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
    }
}

private struct PillIconButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(role == .destructive ? .white : Theme.Palette.text)
                .frame(width: 28, height: 28)
                .background(background, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        if role == .destructive {
            return Theme.Palette.recording.opacity(isHovering ? 0.85 : 1)
        }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }
}

/// 押している間だけわずかに沈める。
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - ドラッグで移動

/// つかんでパネルを動かすための透明な面。
///
/// SwiftUI の `WindowDragGesture` は、ほかのアプリが前面にあるときの
/// 最初のクリックを受け取れず、パネルが動かない。AppKit の `performDrag(with:)` で
/// ウインドウサーバに移動を任せる。画面の端への吸着や複数画面の跨ぎも OS が面倒を見る。
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        // 前面にいなくても 1 回目のクリックからつかめるようにする
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
