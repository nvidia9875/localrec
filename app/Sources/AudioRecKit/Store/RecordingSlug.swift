import Foundation

/// 録音ディレクトリ名 (= 録音 ID) の生成。
///
/// 形式: `2026-08-11_141230_設計レビュー`
///
/// ディレクトリ名はそのままファイルシステムに書くので、以下を必ず潰す:
/// - パス区切り `/` と HFS 由来の `:`
/// - 制御文字 (ターミナル表示を壊す)
/// - 255 UTF-8 バイトの上限 (日本語は1文字3バイトなので簡単に超える)
public enum RecordingSlug {
    /// タイトル部分の最大バイト数。日付部分と連番サフィックスの余地を残して抑えめにする。
    static let maxTitleBytes = 120

    /// タイトルが空・記号のみだったときの代替名。
    static let fallbackTitle = "無題"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// 日付とタイトルから録音 ID を作る。
    public static func make(date: Date, title: String) -> String {
        "\(dateFormatter.string(from: date))_\(sanitize(title))"
    }

    /// タイトルをディレクトリ名として安全な文字列に整える。
    public static func sanitize(_ title: String) -> String {
        let cleaned = String(
            title.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                if CharacterSet.whitespaces.contains(scalar) { return " " }
                return Character(scalar)
            }
        )

        // 空白の連続を1つの `_` に畳む
        let collapsed = cleaned
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: "_")

        // 先頭の `.` は不可視ファイルになるので落とす。末尾の `.` `_` `-` も落とす。
        let trimmed = collapsed
            .drop(while: { $0 == "." })
            .reversed().drop(while: { $0 == "." || $0 == "_" || $0 == "-" }).reversed()

        let result = truncateToBytes(String(trimmed), limit: maxTitleBytes)
        return result.isEmpty ? fallbackTitle : result
    }

    /// UTF-8 バイト数の上限で切り詰める。文字 (Character) 単位で削るので
    /// 結合文字やサロゲートペアを壊さない。
    static func truncateToBytes(_ s: String, limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var out = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > limit { break }
            out.append(ch)
            bytes += n
        }
        return out
    }

    /// 既に使われている ID と衝突しない ID を返す。
    /// 衝突したら `-2`, `-3` … と連番を足す。
    public static func deduplicated(_ id: String, existing: Set<String>) -> String {
        guard existing.contains(id) else { return id }
        var n = 2
        while existing.contains("\(id)-\(n)") {
            n += 1
        }
        return "\(id)-\(n)"
    }
}
