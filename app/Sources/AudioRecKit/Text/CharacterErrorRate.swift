import Foundation

/// 文字誤り率 (CER) の測定結果。
public struct ErrorRateResult: Sendable, Equatable {
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int
    public let referenceLength: Int

    public var errors: Int { substitutions + insertions + deletions }

    /// 誤り率。正解が空のときは、仮説も空なら 0、そうでなければ 1 とする。
    public var rate: Double {
        guard referenceLength > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceLength)
    }

    public var percentage: Double { rate * 100 }
}

/// 文字誤り率 (Character Error Rate)。
///
/// 日本語は語境界が無いため、単語誤り率 (WER) は形態素解析器の性能に
/// 結果が引きずられる。文字単位で測る方が、エンジン同士の比較として素直。
public enum CharacterErrorRate {

    /// 正規化してから測る。
    /// 既定では句読点の違いも数字の表記ゆれも誤りに数えない。
    public static func measure(
        reference: String,
        hypothesis: String,
        removePunctuation: Bool = true,
        normalizeNumbers: Bool = true,
        foldKana: Bool = true
    ) -> ErrorRateResult {
        let ref = Array(
            JapaneseText.normalizeForComparison(
                reference, removePunctuation: removePunctuation,
                normalizeNumbers: normalizeNumbers, foldKana: foldKana))
        let hyp = Array(
            JapaneseText.normalizeForComparison(
                hypothesis, removePunctuation: removePunctuation,
                normalizeNumbers: normalizeNumbers, foldKana: foldKana))
        return align(reference: ref, hypothesis: hyp)
    }

    /// 正規化済みの文字列同士を突き合わせ、置換・挿入・削除の内訳を出す。
    ///
    /// 距離だけでなく内訳を出すのは、置換が多い (認識ミス) のか
    /// 挿入が多い (ハルシネーション) のかで打ち手が変わるため。
    static func align(reference: [Character], hypothesis: [Character]) -> ErrorRateResult {
        let n = reference.count
        let m = hypothesis.count

        if n == 0 {
            return ErrorRateResult(
                substitutions: 0, insertions: m, deletions: 0, referenceLength: 0)
        }
        if m == 0 {
            return ErrorRateResult(
                substitutions: 0, insertions: 0, deletions: n, referenceLength: n)
        }

        // 内訳を復元するため、各セルに (コスト, 置換数, 挿入数, 削除数) を持たせる
        struct Cell {
            var cost = 0
            var substitutions = 0
            var insertions = 0
            var deletions = 0
        }

        var previous = (0...m).map { j in
            Cell(cost: j, substitutions: 0, insertions: j, deletions: 0)
        }

        for i in 1...n {
            var current = [Cell](repeating: Cell(), count: m + 1)
            current[0] = Cell(cost: i, substitutions: 0, insertions: 0, deletions: i)

            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    current[j] = previous[j - 1]
                    current[j].cost = previous[j - 1].cost
                    continue
                }

                var substitution = previous[j - 1]
                substitution.cost += 1
                substitution.substitutions += 1

                var insertion = current[j - 1]
                insertion.cost += 1
                insertion.insertions += 1

                var deletion = previous[j]
                deletion.cost += 1
                deletion.deletions += 1

                current[j] = [substitution, insertion, deletion].min { $0.cost < $1.cost }!
            }
            previous = current
        }

        let final = previous[m]
        return ErrorRateResult(
            substitutions: final.substitutions,
            insertions: final.insertions,
            deletions: final.deletions,
            referenceLength: n
        )
    }
}
