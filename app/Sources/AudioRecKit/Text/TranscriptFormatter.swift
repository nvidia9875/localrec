import Foundation

/// `transcript.json` から人間向けの派生ファイルを作る。
///
/// Markdown は既存の `meeting-notes` スキルが読む形式
/// (`[mm:ss] 話者: テキスト`) に合わせてあり、そのまま要約フローに渡せる。
public enum TranscriptFormatter {

    public static func markdown(_ transcript: Transcript, meta: RecordingMeta? = nil) -> String {
        var lines: [String] = []

        if let meta {
            lines.append("# \(meta.title)")
            lines.append("")
            lines.append("- 録音日時: \(headerDateFormatter.string(from: meta.createdAt))")
            lines.append("- 長さ: \(TimeCode.duration(meta.duration))")
            if let engine = meta.engine {
                let model = meta.model.map { " (\($0))" } ?? ""
                lines.append("- エンジン: \(engine.displayName)\(model)")
            }
            if !meta.participants.isEmpty {
                lines.append("- 登場人物: \(meta.participants.joined(separator: "、"))")
            }
            lines.append("")
        }

        for segment in transcript.segments {
            lines.append(line(for: segment))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// 1セグメント分の行。`[00:12] 自分: テキスト`
    /// 話者が unknown のときは話者部分ごと省く。
    static func line(for segment: TranscriptSegment) -> String {
        let stamp = "[\(TimeCode.short(segment.start))]"
        let name = segment.speaker.displayName
        return name.isEmpty
            ? "\(stamp) \(segment.text)"
            : "\(stamp) \(name): \(segment.text)"
    }

    public static func srt(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(TimeCode.srt(segment.start)) --> \(TimeCode.srt(segment.end))
            \(srtText(for: segment))
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private static func srtText(for segment: TranscriptSegment) -> String {
        let name = segment.speaker.displayName
        return name.isEmpty ? segment.text : "\(name): \(segment.text)"
    }

    /// タイムスタンプ無しの素のテキスト。エクスポートと全文検索で使う。
    public static func plainText(_ transcript: Transcript) -> String {
        transcript.segments.map { segment in
            let name = segment.speaker.displayName
            return name.isEmpty ? segment.text : "\(name): \(segment.text)"
        }.joined(separator: "\n") + "\n"
    }

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = .current
        return f
    }()
}
