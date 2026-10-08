import Foundation
import Testing

@testable import AudioRecKit

@Suite("漢数字の正規化")
struct JapaneseNumeralsTests {

    @Test("単位つきの漢数字を数値にする", arguments: [
        ("五", 5),
        ("十", 10),
        ("十五", 15),
        ("八十七", 87),
        ("百二十", 120),
        ("千二百", 1_200),
        ("二千二十六", 2_026),
        ("三万五千", 35_000),
        ("二億三千万", 230_000_000),
        ("四十八", 48),
        ("七百八十", 780),
    ])
    func parsesWithUnits(input: String, expected: Int) {
        #expect(JapaneseNumerals.parse(Array(input)) == expected)
    }

    @Test("単位を含まない並びは位取りとして読む")
    func parsesPositionalDigits() {
        // 「二〇二六年」のような書き方
        #expect(JapaneseNumerals.parse(Array("二〇二六")) == 2_026)
        #expect(JapaneseNumerals.parse(Array("〇")) == 0)
    }

    @Test("文中の漢数字だけを置き換える")
    func replacesWithinSentence() {
        #expect(
            JapaneseNumerals.toArabic("二千二十六年八月十一日の十四時三十分から始めます。")
                == "2026年8月11日の14時30分から始めます。")
        #expect(JapaneseNumerals.toArabic("予算は三万五千円です") == "予算は35000円です")
    }

    @Test("数字を含まない文はそのまま返す")
    func leavesNonNumericTextAlone() {
        #expect(JapaneseNumerals.toArabic("おはようございます") == "おはようございます")
        #expect(JapaneseNumerals.toArabic("") == "")
    }

    @Test("すでにアラビア数字の部分は値が変わらない")
    func keepsArabicDigits() {
        #expect(JapaneseNumerals.toArabic("2026年8月") == "2026年8月")
    }

    @Test("アラビア数字と漢数字の単位が混ざった表記を解く")
    func parsesMixedNotation() {
        // 音声認識は「2億3000万」のように混ぜて出してくる
        #expect(JapaneseNumerals.toArabic("2億3000万円") == "230000000円")
        #expect(JapaneseNumerals.toArabic("3万5000円") == "35000円")
        #expect(JapaneseNumerals.toArabic("1200件") == "1200件")
    }

    @Test("桁区切りのカンマを数字の間からだけ外す")
    func removesDigitGroupSeparators() {
        #expect(JapaneseNumerals.removeDigitGroupSeparators("35,000円") == "35000円")
        #expect(JapaneseNumerals.removeDigitGroupSeparators("1,234,567") == "1234567")
        // 文の区切りのカンマは残す
        #expect(JapaneseNumerals.removeDigitGroupSeparators("はい,そうです") == "はい,そうです")
        #expect(JapaneseNumerals.removeDigitGroupSeparators("3,あ") == "3,あ")
    }
}

@Suite("数字を含む CER の測り方")
struct NumberNormalizationCERTests {

    @Test("漢数字とアラビア数字の違いは誤りに数えない")
    func notationDifferenceIsNotAnError() {
        // どちらも正しい表記。正規化しないと数字を含む文の CER が
        // 実態の数倍に膨らみ、本当の認識ミスが埋もれる。
        let result = CharacterErrorRate.measure(
            reference: "二千二十六年八月十一日の十四時三十分から始めます。",
            hypothesis: "2026年8月11日の14時30分から始めます。")
        #expect(result.rate == 0)
    }

    @Test("パーセントと % の違いも誤りに数えない")
    func percentAliasIsNotAnError() {
        let result = CharacterErrorRate.measure(
            reference: "全体の八十七パーセントが完了しています。",
            hypothesis: "全体の87%が完了しています。")
        #expect(result.rate == 0)
    }

    @Test("正規化を切れば表記ゆれが誤りとして現れる")
    func rawModeShowsNotationDifference() {
        // 表記ゆれの量を別指標として出せるようにしてある
        let result = CharacterErrorRate.measure(
            reference: "二千二十六年",
            hypothesis: "2026年",
            normalizeNumbers: false)
        #expect(result.rate > 0)
    }

    @Test("数値の途中に空白が入っていても正しく比較する")
    func handlesSpacesInsideNumbers() {
        // 音声認識は「2億 3000万」のように数値の途中に空白を挟んでくる
        let result = CharacterErrorRate.measure(
            reference: "去年の実績は二億三千万円でした。",
            hypothesis: "去年の実績は 2億 3000万円でした。")
        #expect(result.rate == 0)
    }

    @Test("桁区切り入りの金額も一致する")
    func handlesGroupedDigits() {
        let result = CharacterErrorRate.measure(
            reference: "予算は三万五千円を上限としています。",
            hypothesis: "予算は35,000円を上限としています。")
        #expect(result.rate == 0)
    }

    @Test("数値が違えば正規化しても誤りになる")
    func realNumberErrorsStillCount() {
        // 「千二百件」→「1200点」の助数詞ミスは本物の誤り
        let result = CharacterErrorRate.measure(
            reference: "対象は千二百件です", hypothesis: "対象は1200点です")
        #expect(result.substitutions == 1)
    }
}
