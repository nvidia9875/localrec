import Foundation

/// 秒数の表示形式。文字起こしの `[mm:ss]` と SRT のタイムコードを一箇所にまとめる。
public enum TimeCode {
    /// `mm:ss`。1時間を超えたら `h:mm:ss`。負値と NaN は 0 として扱う。
    public static func short(_ seconds: TimeInterval) -> String {
        let total = normalized(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// SRT 用の `HH:MM:SS,mmm`。
    public static func srt(_ seconds: TimeInterval) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(safe)
        let ms = Int((safe - Double(total)) * 1000).clamped(to: 0...999)
        return String(
            format: "%02d:%02d:%02d,%03d",
            total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    /// `32分` / `1時間5分` のような、一覧に出す長さ表記。
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = normalized(seconds)
        if total < 60 { return "\(total)秒" }
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)時間\(m)分" : "\(m)分"
    }

    private static func normalized(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
