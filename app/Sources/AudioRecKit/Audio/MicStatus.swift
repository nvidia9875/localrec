import Foundation

/// 常時表示のマイクパネルに出す状態。
///
/// 録音の状態・マイク権限・入力デバイスの有無は別々の場所から来るので、
/// 「いま何を見せるか」の優先順位をここ 1 か所で決める。
public enum MicStatus: Equatable, Sendable {
    /// 録音していない。マイクは開いていない（OS のマイク使用中表示も点かない）。
    case idle
    case recording
    case paused
    /// 停止後、文字起こしの確定と音声の結合を待っている。
    case saving
    /// 初回だけ発生する音声認識モデルの取得 (0...1)。
    case downloading(Double)
    case permissionDenied
    case noInputDevice

    /// 優先順位: 保存中 > モデル取得中 > 一時停止 > 録音中 > 権限 > デバイス > 待機中。
    ///
    /// 録音が動いている間は、権限やデバイスの状態より録音の状態を出す。
    /// 録れている最中に「マイク無し」と出すと、録れていないと誤解させる。
    public static func derive(
        permission: MicPermission.Status,
        hasInputDevice: Bool,
        isRecording: Bool,
        isPaused: Bool,
        isSaving: Bool,
        downloadProgress: Double?
    ) -> MicStatus {
        if isSaving { return .saving }
        if let downloadProgress { return .downloading(downloadProgress) }
        if isRecording { return isPaused ? .paused : .recording }
        // 未確定は「録音の開始時に尋ねる」ので、ここでは止めない
        if permission == .denied { return .permissionDenied }
        if !hasInputDevice { return .noInputDevice }
        return .idle
    }

    /// パネルから新しい録音を始められるか。
    public var canStart: Bool { self == .idle }
}
