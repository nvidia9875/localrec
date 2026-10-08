import Foundation
import Testing

@testable import AudioRecKit

@Suite("日本語テキストの整形")
struct JapaneseTextTidyTests {

    @Test("閉じ記号の前の空白を落とす")
    func removesSpaceBeforeClosingMarks() {
        // 音声認識は「ですか ？」のように記号の前に空白を入れてくる
        #expect(JapaneseText.tidy("どうですか ？") == "どうですか？")
        #expect(JapaneseText.tidy("はい 。") == "はい。")
        #expect(JapaneseText.tidy("そう 、思います") == "そう、思います")
    }

    @Test("開き記号の後の空白を落とす")
    func removesSpaceAfterOpeningMarks() {
        #expect(JapaneseText.tidy("「 こんにちは」") == "「こんにちは」")
    }

    @Test("英単語の間の空白は残す")
    func keepsSpacesBetweenLatinWords() {
        // ここを潰すと英語混じりの発話が読めなくなる
        #expect(JapaneseText.tidy("pull request を送ります") == "pull request を送ります")
        #expect(JapaneseText.tidy("Apple Silicon は速い") == "Apple Silicon は速い")
    }

    @Test("空白の連続を 1 つに畳む")
    func collapsesRepeatedSpaces() {
        #expect(JapaneseText.tidy("a   b") == "a b")
    }

    @Test("前後の空白を落とす")
    func trimsEdges() {
        #expect(JapaneseText.tidy("  こんにちは  ") == "こんにちは")
        #expect(JapaneseText.tidy("") == "")
    }
}

@Suite("CER 比較用の正規化")
struct JapaneseTextNormalizeTests {

    @Test("全角英数を半角に揃える")
    func normalizesFullWidthAlphanumerics() {
        #expect(JapaneseText.normalizeForComparison("ＡＢＣ１２３") == "abc123")
    }

    @Test("半角カナと全角カナを同一視する")
    func normalizesHalfWidthKana() {
        #expect(
            JapaneseText.normalizeForComparison("ｶﾀｶﾅ")
                == JapaneseText.normalizeForComparison("カタカナ"))
    }

    @Test("英字の大小を無視する")
    func lowercasesLatin() {
        #expect(JapaneseText.normalizeForComparison("Kubernetes") == "kubernetes")
    }

    @Test("空白は誤りに数えない")
    func removesWhitespace() {
        // 日本語に語境界は無く、空白の有無は認識の誤りではない
        #expect(
            JapaneseText.normalizeForComparison("こんにちは 世界")
                == JapaneseText.normalizeForComparison("こんにちは世界"))
    }

    @Test("句読点の違いを誤りに数えない (既定)")
    func removesPunctuationByDefault() {
        #expect(
            JapaneseText.normalizeForComparison("はい。そうです、ね")
                == JapaneseText.normalizeForComparison("はいそうですね"))
    }

    @Test("句読点を残す指定もできる")
    func canKeepPunctuation() {
        #expect(JapaneseText.normalizeForComparison("はい。", removePunctuation: false) == "はい。")
    }

    @Test("カタカナとひらがなの書き分けを誤りに数えない")
    func foldsKana() {
        // 「ずれ」と「ズレ」は同じ語の別表記であって認識の誤りではない
        #expect(
            JapaneseText.normalizeForComparison("認識のずれ")
                == JapaneseText.normalizeForComparison("認識のズレ"))
    }

    @Test("カタカナの畳み込みは無効にもできる")
    func canDisableKanaFolding() {
        #expect(
            JapaneseText.normalizeForComparison("ズレ", foldKana: false)
                != JapaneseText.normalizeForComparison("ずれ", foldKana: false))
    }

    @Test("長音符は語の一部なので残す")
    func keepsProlongedSoundMark() {
        // 「コンピューター」から落とすと別語になり CER が実態より悪化する。
        // カナはひらがなに寄せられるが、長音符はそのまま残る。
        #expect(JapaneseText.normalizeForComparison("コンピューター") == "こんぴゅーたー")
        #expect(JapaneseText.normalizeForComparison("レビュー") == "れびゅー")
    }
}

@Suite("文単位へのまとめ")
struct SentenceGrouperTests {

    @Test("文末で区切る")
    func splitsAtSentenceEnd() {
        let tokens = [
            token("おはよう", 0, 1),
            token("ございます。", 1, 2),
            token("今日は", 2, 3),
            token("晴れです。", 3, 4),
        ]
        let sentences = SentenceGrouper.group(tokens)

        #expect(sentences.map(\.text) == ["おはようございます。", "今日は晴れです。"])
        #expect(sentences[0].start == 0)
        #expect(sentences[0].end == 2)
        #expect(sentences[1].start == 2)
        #expect(sentences[1].end == 4)
    }

    @Test("疑問符・感嘆符でも区切る")
    func splitsAtQuestionAndExclamation() {
        let sentences = SentenceGrouper.group([
            token("そうですか？", 0, 1), token("いいですね！", 1, 2),
        ])
        #expect(sentences.count == 2)
    }

    @Test("文末が無ければ 1 文にまとめる")
    func keepsUnterminatedTextTogether() {
        let sentences = SentenceGrouper.group([token("えーと", 0, 1), token("そうですね", 1, 2)])

        #expect(sentences.count == 1)
        #expect(sentences[0].text == "えーとそうですね")
        #expect(sentences[0].end == 2)
    }

    @Test("句読点が続かない場合は長さで強制的に切る")
    func splitsOnMaxDuration() {
        // 句読点を打たない話し方でも 1 行が延々と伸び続けないようにする
        let tokens = (0..<10).map { i in
            token("あー", TimeInterval(i) * 5, TimeInterval(i + 1) * 5)
        }
        let sentences = SentenceGrouper.group(tokens, maxDuration: 20)

        #expect(sentences.count > 1)
        for sentence in sentences {
            #expect(sentence.duration <= 25)
        }
    }

    @Test("トークンの途中にある文末で切り、時刻を按分する")
    func explodesTokensContainingTerminators() {
        // 1 トークンが 2 文にまたがっていても行のタイムスタンプがずれないようにする
        let sentences = SentenceGrouper.group([token("はい。そうです。", 0, 8)])

        #expect(sentences.map(\.text) == ["はい。", "そうです。"])
        #expect(sentences[0].start == 0)
        #expect(abs(sentences[0].end - 3) < 0.01)  // 8 秒 × 3/8 文字
        #expect(abs(sentences[1].start - 3) < 0.01)
        #expect(sentences[1].end == 8)
    }

    @Test("空のトークンを無視する")
    func ignoresEmptyTokens() {
        #expect(SentenceGrouper.group([]).isEmpty)
        #expect(SentenceGrouper.group([token("   ", 0, 1)]).isEmpty)
    }

    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedToken {
        TimedToken(text: text, start: start, end: end)
    }
}

@Suite("文字誤り率 (CER)")
struct CharacterErrorRateTests {

    @Test("完全一致は 0")
    func identicalIsZero() {
        let result = CharacterErrorRate.measure(reference: "こんにちは", hypothesis: "こんにちは")
        #expect(result.rate == 0)
        #expect(result.errors == 0)
    }

    @Test("置換を数える")
    func countsSubstitutions() {
        // 「設計」→「設定」は 1 文字の置換
        let result = CharacterErrorRate.measure(reference: "設計レビュー", hypothesis: "設定レビュー")
        #expect(result.substitutions == 1)
        #expect(result.insertions == 0)
        #expect(result.deletions == 0)
        #expect(abs(result.rate - 1.0 / 6.0) < 0.001)
    }

    @Test("挿入を数える")
    func countsInsertions() {
        let result = CharacterErrorRate.measure(reference: "あい", hypothesis: "あXい")
        #expect(result.insertions == 1)
        #expect(result.substitutions == 0)
    }

    @Test("削除を数える")
    func countsDeletions() {
        let result = CharacterErrorRate.measure(reference: "あいう", hypothesis: "あう")
        #expect(result.deletions == 1)
    }

    @Test("句読点の違いは既定では誤りにならない")
    func punctuationIgnoredByDefault() {
        let result = CharacterErrorRate.measure(
            reference: "はい。そうです。", hypothesis: "はい、そうです")
        #expect(result.rate == 0)
    }

    @Test("正解が空なら仮説の長さぶん挿入になる")
    func emptyReference() {
        let result = CharacterErrorRate.measure(reference: "", hypothesis: "あいう")
        #expect(result.insertions == 3)
        #expect(result.rate == 1)
    }

    @Test("両方空なら 0")
    func bothEmpty() {
        #expect(CharacterErrorRate.measure(reference: "", hypothesis: "").rate == 0)
    }

    @Test("仮説が空なら全文字が削除になる")
    func emptyHypothesis() {
        let result = CharacterErrorRate.measure(reference: "あいう", hypothesis: "")
        #expect(result.deletions == 3)
        #expect(result.rate == 1)
    }

    @Test("ハルシネーションは挿入として現れる")
    func hallucinationShowsAsInsertions() {
        // Whisper の無音ハルシネーション対策の効果を、挿入数の減少で測れるようにする
        let result = CharacterErrorRate.measure(
            reference: "本日はここまでです",
            hypothesis: "本日はここまでですご視聴ありがとうございました")
        #expect(result.insertions == 14)  // 「ご視聴ありがとうございました」= 14 文字
        #expect(result.substitutions == 0)
    }
}
