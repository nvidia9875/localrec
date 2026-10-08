import Foundation

/// 保存音声の形式。
/// - `m4a`: 保管用 (AAC 圧縮)
/// - `wav`: ASR 入力用 (16kHz mono PCM)。容量を食うので後から削除可能にする。
public enum AudioFormat: String, Sendable, CaseIterable {
    case m4a
    case wav
}

/// ディスク上のレイアウトを一箇所に集約する。
///
/// 真実の源はファイルシステムに置く。Finder でも Claude でも直接読めることを
/// 優先し、SQLite は再構築可能な検索キャッシュとしてしか使わない。
public struct StoragePaths: Sendable {
    public let root: URL

    /// 既定は `~/Documents/AudioRec`。テストでは差し替える。
    public static var defaultRoot: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioRec", isDirectory: true)
    }

    public init(root: URL = StoragePaths.defaultRoot) {
        self.root = root
    }

    public var indexDirectory: URL {
        root.appendingPathComponent(".index", isDirectory: true)
    }

    public var searchIndexFile: URL {
        indexDirectory.appendingPathComponent("search.sqlite")
    }

    public var glossaryFile: URL {
        root.appendingPathComponent("glossary.json")
    }

    public func recordingDirectory(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func metaFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("meta.json")
    }

    public func transcriptFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("transcript.json")
    }

    public func transcriptMarkdownFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("transcript.md")
    }

    public func transcriptSRTFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("transcript.srt")
    }

    public func summaryFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("summary.md")
    }

    /// 人が書くメモ。要約の材料になるので、文字起こしと同じ場所に素の Markdown で置く。
    public func memoFile(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("memo.md")
    }

    public func audioDirectory(_ id: String) -> URL {
        recordingDirectory(id).appendingPathComponent("audio", isDirectory: true)
    }

    /// 保管用の音声ファイル。例: `audio/mic.m4a`
    public func audioFile(_ id: String, track: TrackKind, format: AudioFormat = .m4a) -> URL {
        audioDirectory(id).appendingPathComponent("\(track.rawValue).\(format.rawValue)")
    }

    /// ASR 入力用の 16kHz mono WAV。例: `audio/asr_mic.wav`
    public func asrAudioFile(_ id: String, track: TrackKind) -> URL {
        audioDirectory(id).appendingPathComponent("asr_\(track.rawValue).wav")
    }
}
