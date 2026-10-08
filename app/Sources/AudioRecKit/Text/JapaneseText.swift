import Foundation

/// 日本語テキストの整形と正規化。
///
/// 用途が 2 つあるので関数を分けている:
/// - `tidy`: 保存・表示する本文を読みやすくする (意味を変えない範囲)
/// - `normalizeForComparison`: CER を測るために表記ゆれを潰す (見た目は壊れてよい)
public enum JapaneseText {

    /// 日本語の閉じ記号。この直前の空白は不要。
    private static let closingMarks: Set<Character> = [
        "。", "、", "，", "．", "？", "！", "」", "』", "）", "〉", "》", "]", ")", ",", ".",
    ]
    /// 日本語の開き記号。この直後の空白は不要。
    private static let openingMarks: Set<Character> = ["「", "『", "（", "〈", "《", "[", "("]

    /// 表示用の軽い整形。
    ///
    /// 音声認識は「ですか ？」のように記号の前に空白を入れてくることがある。
    /// 英単語の間の空白は残す必要があるので、記号まわりだけを対象にする。
    public static func tidy(_ text: String) -> String {
        var result = ""
        var pendingSpace = false

        for character in text {
            if character == " " || character == "\u{3000}" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                let afterOpening = result.last.map { openingMarks.contains($0) } ?? true
                if !closingMarks.contains(character) && !afterOpening {
                    result.append(" ")
                }
                pendingSpace = false
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 単位の書き方ゆれ。どちらの表記も正しく、認識の誤りではない。
    private static let unitAliases: [(String, String)] = [
        ("パーセント", "%")
    ]

    /// CER 比較用の正規化。
    ///
    /// - NFKC 正規化 (全角英数 → 半角、半角カナ → 全角)
    /// - 英字を小文字に
    /// - `normalizeNumbers` が true なら漢数字をアラビア数字に、単位表記も統一
    /// - 空白をすべて除去 (日本語は語境界が無く、空白の有無は誤りではない)
    /// - `removePunctuation` が true なら句読点・記号も除去
    ///
    /// 数字の正規化を既定で有効にしているのは実測の結果による。
    /// 無効のままだと「二千二十六年」対「2026年」のような表記ゆれが
    /// 誤りとして数えられ、数字を含む文の CER が実態の数倍に膨らんで、
    /// 本当の認識ミスが埋もれてしまった。
    public static func normalizeForComparison(
        _ text: String,
        removePunctuation: Bool = true,
        normalizeNumbers: Bool = true,
        foldKana: Bool = true
    ) -> String {
        var normalized = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()


        // 空白は数値変換より先に落とす。
        // 音声認識は「2億 3000万」のように数値の途中に空白を挟むことがあり、
        // 残したままだと数値の並びが分断されて別々の数として解釈される。
        normalized = String(
            normalized.unicodeScalars.compactMap { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar) ? nil : Character(scalar)
            })

        if normalizeNumbers {
            for (from, to) in unitAliases {
                normalized = normalized.replacingOccurrences(of: from, with: to)
            }
            // 桁区切りも数値変換より先に外す。理由は空白と同じ。
            normalized = JapaneseNumerals.removeDigitGroupSeparators(normalized)
            normalized = JapaneseNumerals.toArabic(normalized)
        }

        // カタカナとひらがなの書き分けは同じ語の別表記であって認識の誤りではない
        //（「ずれ」と「ズレ」など）。ひらがなに寄せて比較する。
        // 単位の別名（パーセント）を潰した後に行う必要がある。
        if foldKana {
            normalized = katakanaToHiragana(normalized)
        }

        guard removePunctuation else { return normalized }

        return String(
            normalized.unicodeScalars.compactMap { scalar -> Character? in
                isPunctuation(scalar) ? nil : Character(scalar)
            })
    }

    /// カタカナをひらがなに写す。
    ///
    /// ICU の `.hiraganaToKatakana` を逆方向に使うと長音符まで母音に展開されてしまい
    /// （「コンピューター」→「こんぴゅうたあ」）、比較用としては壊れる。
    /// 文字コードの対応が単純な範囲だけを、自前で写す。
    private static func katakanaToHiragana(_ text: String) -> String {
        // ァ(U+30A1) 〜 ヶ(U+30F6) は ぁ(U+3041) 〜 ゖ(U+3096) と 0x60 差で並ぶ。
        // 長音符 ー(U+30FC) と中黒 ・(U+30FB) はこの範囲の外なので影響を受けない。
        let katakanaStart: UInt32 = 0x30A1
        let katakanaEnd: UInt32 = 0x30F6
        let offset: UInt32 = 0x60

        return String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { scalar in
                    guard scalar.value >= katakanaStart, scalar.value <= katakanaEnd,
                          let folded = Unicode.Scalar(scalar.value - offset)
                    else { return scalar }
                    return folded
                }))
    }

    /// 長音符「ー」は語の一部なので、記号として落としてはいけない。
    /// 「コンピューター」から落とすと別語になり、CER が実態より悪化する。
    private static let japanesePunctuation: Set<Unicode.Scalar> = Set(
        "。、・「」『』〜…".unicodeScalars)

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if japanesePunctuation.contains(scalar) { return true }
        if scalar == "ー" { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }
}
