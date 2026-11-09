import Foundation
import Testing

@testable import AudioRecKit

@Suite("マイクパネルの状態判定")
struct MicStatusTests {

    private func derive(
        permission: MicPermission.Status = .granted,
        hasInputDevice: Bool = true,
        isRecording: Bool = false,
        isPaused: Bool = false,
        isSaving: Bool = false,
        downloadProgress: Double? = nil
    ) -> MicStatus {
        MicStatus.derive(
            permission: permission, hasInputDevice: hasInputDevice,
            isRecording: isRecording, isPaused: isPaused, isSaving: isSaving,
            downloadProgress: downloadProgress)
    }

    @Test("何もしていなければ待機中")
    func idleByDefault() {
        #expect(derive() == .idle)
    }

    @Test("録音中で止めていなければ録音中")
    func recording() {
        #expect(derive(isRecording: true) == .recording)
    }

    @Test("一時停止中は録音中より優先する")
    func pausedWinsOverRecording() {
        #expect(derive(isRecording: true, isPaused: true) == .paused)
    }

    @Test("保存中は一時停止より優先する（停止ボタンを押した後）")
    func savingWinsOverPaused() {
        #expect(derive(isRecording: true, isPaused: true, isSaving: true) == .saving)
    }

    @Test("モデル取得中は録音の開始前でも出す")
    func downloadingShowsProgress() {
        #expect(derive(downloadProgress: 0.42) == .downloading(0.42))
    }

    @Test("権限が拒否されていれば、待機中でなく未許可を出す")
    func permissionDenied() {
        #expect(derive(permission: .denied) == .permissionDenied)
    }

    @Test("権限が未確定なら待機中として扱う（録音の開始時に尋ねる）")
    func undeterminedIsIdle() {
        #expect(derive(permission: .undetermined) == .idle)
    }

    @Test("入力デバイスが無ければ待機中でなくマイク無しを出す")
    func noInputDevice() {
        #expect(derive(hasInputDevice: false) == .noInputDevice)
    }

    @Test("録音が動いている間は権限・デバイスの状態より録音の状態を出す")
    func recordingWinsOverEnvironment() {
        #expect(derive(permission: .denied, hasInputDevice: false, isRecording: true) == .recording)
    }

    @Test("録音を始められるのは待機中だけ")
    func canStartOnlyWhenIdle() {
        #expect(MicStatus.idle.canStart)
        #expect(!MicStatus.recording.canStart)
        #expect(!MicStatus.paused.canStart)
        #expect(!MicStatus.saving.canStart)
        #expect(!MicStatus.downloading(0.5).canStart)
        #expect(!MicStatus.permissionDenied.canStart)
        #expect(!MicStatus.noInputDevice.canStart)
    }
}
