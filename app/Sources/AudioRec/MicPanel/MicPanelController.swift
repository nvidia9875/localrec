import AppKit
import AudioRecKit
import Observation
import SwiftUI

/// マイクの権限と既定の入力デバイス。録音していない間もパネルに出すために持つ。
///
/// どちらもマイクを開かずに読める。待機中に入力レベルを測らないのは、
/// 測るとマイクを開きっぱなしになり、OS のマイク使用中表示が点き続けるため。
@MainActor
@Observable
final class MicEnvironment {
    private(set) var permission: MicPermission.Status = MicPermission.status
    private(set) var deviceName: String?

    @ObservationIgnored private var observer: InputDeviceObserver?
    @ObservationIgnored private var activationToken: NSObjectProtocol?

    init() {}

    /// デバイスの切り替えと、アプリに戻ってきたときの権限の変化を追い始める。
    func startObserving() {
        observer = InputDeviceObserver { [weak self] name in
            self?.deviceName = name
        }
        activationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    func refreshPermission() {
        let current = MicPermission.status
        if current != permission { permission = current }
    }

    /// スナップショット用に値を差し込む。
    func inject(permission: MicPermission.Status, deviceName: String?) {
        self.permission = permission
        self.deviceName = deviceName
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// 他のアプリの上にも浮かび続けるパネル。
///
/// クリックしてもアプリを前面に出さない（`.nonactivatingPanel`）。
/// 会議アプリを操作しながら一時停止・停止を押せるようにするため。
private final class MicPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ほかのアプリが前面にあるときも、1 回目のクリックでボタンが効くようにする。
/// 既定では 1 回目はパネルを前に出すだけで消費され、「押したのに止まらない」になる。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 常時表示のマイクパネルを出し入れする。
@MainActor
@Observable
final class MicPanelController {
    private static let visibilityKey = "showsMicPanel"
    private static let frameAutosaveName = "AudioRecMicPanel"
    /// 初回の置き場所: 画面下端（Dock の上）からの距離。
    private static let bottomInset: CGFloat = 24

    /// パネルを出しているか。終了しても覚えておく（既定は出す）。
    private(set) var isVisible: Bool

    @ObservationIgnored private var panel: MicPanel?
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let environment = MicEnvironment()
    @ObservationIgnored private let onOpenMain: () -> Void

    init(model: AppModel, onOpenMain: @escaping () -> Void) {
        self.model = model
        self.onOpenMain = onOpenMain
        let stored = UserDefaults.standard.object(forKey: Self.visibilityKey) as? Bool
        self.isVisible = stored ?? true
    }

    /// 起動時に呼ぶ。前回隠していたら出さない。
    func install() {
        environment.startObserving()
        if isVisible { show() }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        setVisible(true)
    }

    func hide() {
        panel?.orderOut(nil)
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.visibilityKey)
    }

    private func makePanel() -> MicPanel {
        let margin = MicPillContent.Metrics.shadowMargin * 2
        let size = CGSize(
            width: MicPillContent.Metrics.width + margin,
            height: MicPillContent.Metrics.height + margin)

        let panel = MicPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // 他のアプリの通常ウインドウより上。全デスクトップ・フルスクリーンの上にも出す
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 影はピルの形に合わせて SwiftUI 側で描く。窓の影は四角く出てしまう
        panel.hasShadow = false
        panel.title = "マイク"

        let hosting = FirstMouseHostingView(
            rootView: MicPillView(model: model, environment: environment, onOpenMain: onOpenMain))
        hosting.frame = CGRect(origin: .zero, size: size)
        // 状態で中身が変わっても窓の大きさは変えない。位置が跳ねると押し間違える
        hosting.sizingOptions = []
        panel.contentView = hosting

        // 動かした位置を次の起動でも使う。初回だけ画面下中央に置く
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setFrameOrigin(Self.defaultOrigin(for: size))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        return panel
    }

    private static func defaultOrigin(for size: CGSize) -> CGPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return .zero }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + bottomInset)
    }
}
