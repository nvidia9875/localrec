import AVFoundation
import Foundation

/// マイクの TCC 権限。
public enum MicPermission {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        case undetermined
    }

    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// 未確定ならダイアログを出す。確定済みなら現在の状態をそのまま返す。
    public static func request() async -> Status {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        }
    }

    /// 拒否されているときにユーザーに見せる案内。
    public static let deniedGuidance = """
        マイクへのアクセスが許可されていません。
        システム設定 → プライバシーとセキュリティ → マイク で AudioRec を有効にしてください。
        """
}
