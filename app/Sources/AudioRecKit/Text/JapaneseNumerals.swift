import Foundation

/// 漢数字をアラビア数字に揃える。
///
/// なぜ必要か: 「二千二十六年」と「2026年」はどちらも正しい表記で、
/// 音声認識の誤りではない。正規化せずに CER を測ると、数字を含む文の
/// 誤り率が実態の何倍にも膨らみ、本当の認識ミスが埋もれる。
///
/// 限界: 形態素解析をしないので、数字の文字を含む語（「四半期」など）を
/// 数値と誤認することがある。ただし正解と認識結果の双方に同じ変換を
/// かけるため、多くの場合は相殺される。評価用の正規化であり、
/// 表示用テキストには使わない。
public enum JapaneseNumerals {

    private static let digits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]

    /// 十・百・千。数字が前に無ければ 1 とみなす（「十五」= 15）。
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    /// 万・億・兆。ここまでで区切って積み上げる。
    private static let largeUnits: [Character: Int] = [
        "万": 10_000, "億": 100_000_000, "兆": 1_000_000_000_000,
    ]

    /// アラビア数字も数値の一部として扱う。
    ///
    /// 音声認識は「2億3000万」のように、アラビア数字と漢数字の単位を混ぜて出す。
    /// ここを拾わないと「二億三千万」との比較で全文字が誤りになる。
    private static func digitValue(_ character: Character) -> Int? {
        if let value = digits[character] { return value }
        if let ascii = character.wholeNumberValue, character.isASCII { return ascii }
        return nil
    }

    private static func isNumeral(_ character: Character) -> Bool {
        digitValue(character) != nil || smallUnits[character] != nil || largeUnits[character] != nil
    }

    /// 桁区切りのカンマを数字の間からだけ取り除く。
    ///
    /// 「35,000」を先に「35000」にしておかないと、カンマで数値の並びが
    /// 分断されて「35」と「000」の 2 つに割れてしまう。
    public static func removeDigitGroupSeparators(_ text: String) -> String {
        let characters = Array(text)
        var result = ""

        for (index, character) in characters.enumerated() {
            let isSeparator = character == "," || character == "，"
            let betweenDigits =
                index > 0 && index + 1 < characters.count
                && digitValue(characters[index - 1]) != nil
                && digitValue(characters[index + 1]) != nil
            if isSeparator && betweenDigits { continue }
            result.append(character)
        }
        return result
    }

    /// 文字列中の漢数字の並びをアラビア数字に置き換える。
    public static func toArabic(_ text: String) -> String {
        var result = ""
        var run: [Character] = []

        func flush() {
            guard !run.isEmpty else { return }
            result += String(parse(run))
            run.removeAll()
        }

        for character in text {
            if isNumeral(character) {
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// 漢数字の並びを整数に変換する。
    static func parse(_ characters: [Character]) -> Int {
        // 単位を含まない並びは位取り表記とみなす（「二〇二六」= 2026、「2026」= 2026）
        let hasUnit = characters.contains { smallUnits[$0] != nil || largeUnits[$0] != nil }
        if !hasUnit {
            return characters.reduce(0) { $0 * 10 + (digitValue($1) ?? 0) }
        }

        var total = 0
        var section = 0
        var current = 0

        for character in characters {
            if let digit = digitValue(character) {
                current = current * 10 + digit
            } else if let unit = smallUnits[character] {
                // 「十」は前に数字が無ければ 1 として扱う
                section += (current == 0 ? 1 : current) * unit
                current = 0
            } else if let unit = largeUnits[character] {
                total += (section + current) * unit
                section = 0
                current = 0
            }
        }
        return total + section + current
    }
}
