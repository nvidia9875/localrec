import AVFoundation
import Foundation

/// 文字起こしエンジンから流れてくるイベント。
public enum ASREvent: Sendable {
    /// まだ確定していないテキスト。次のイベントで置き換わる前提で、UI では薄く出す。
    case volatile(String)
    /// 確定したセグメント。これを積み上げたものが `transcript.json` になる。
    case finalized(TranscriptSegment)
}

/// エンジンの準備状態。モデル資産の有無を UI に伝えるために使う。
public enum ASRReadiness: Sendable, Equatable {
    case ready
    /// モデル資産が未取得。初回にダウンロードが要る。
    case needsDownload
    /// この環境では使えない (言語未対応など)。
    case unsupported(reason: String)
}

public enum ASREngineError: LocalizedError {
    case localeNotSupported(String)
    case notPrepared
    case alreadyRunning
    case audioFormatUnavailable
    case conversionFailed(String)
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case .localeNotSupported(let id):
            "この言語には対応していません: \(id)"
        case .notPrepared:
            "エンジンの準備ができていません"
        case .alreadyRunning:
            "すでに文字起こしを実行中です"
        case .audioFormatUnavailable:
            "エンジンが受け付ける音声形式を取得できませんでした"
        case .conversionFailed(let d):
            "音声形式を変換できませんでした: \(d)"
        case .engineFailure(let d):
            "文字起こしに失敗しました: \(d)"
        }
    }
}

/// 文字起こしエンジンの共通インターフェース。
///
/// Apple の SpeechAnalyzer と mlx-whisper サイドカーをこの裏に置くことで、
/// UI もベンチマークも同じコードパスで両方を扱える。
public protocol ASREngine: Actor {
    nonisolated var kind: ASREngineKind { get }

    /// 使える状態か調べる。モデルのダウンロードは行わない。
    func readiness() async -> ASRReadiness

    /// 必要ならモデル資産を取得する。`progress` は 0...1。
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// ライブ文字起こしを開始し、イベントの流れを返す。
    func startLive(speaker: SpeakerRole) async throws -> AsyncStream<ASREvent>

    /// 音声を投入する。`startLive` の後にのみ有効。
    func feed(_ buffer: AVAudioPCMBuffer) async

    /// 入力の終了を伝え、残りを確定させる。
    func finishLive() async

    /// 音声ファイルを一括で文字起こしする。
    func transcribeFile(at url: URL, speaker: SpeakerRole) async throws -> Transcript
}

extension ASREngine {
    /// 進捗コールバック不要な呼び出し向けの糖衣。
    public func prepare() async throws {
        try await prepare(progress: nil)
    }
}
