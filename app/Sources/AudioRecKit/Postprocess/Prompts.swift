import Foundation

/// `claude -p` に渡すプロンプト。
///
/// 文字起こしの整形は「意味を変えない変換」であることが最重要。
/// 要約に寄せた書き換えをされると、元の発言が失われて後から検証できなくなる。
public enum Prompts {

    /// 整形。セグメントの配列を受け取り、同じ長さの配列を返させる。
    public static func polish(glossary: Glossary = .empty) -> String {
        var lines = [
            "入力は文字起こしのセグメント配列(JSON)です。各要素について、",
            "フィラー(えーと/あの/その/まあ/なんというか等)と意味の無い相槌の重複を取り除き、",
            "句読点を整え、読みやすい日本語にしてください。",
            "",
            "厳守事項:",
            "- 出力は JSON 配列のみ。前置きも説明もコードフェンスも付けない。",
            "- 要素数は入力と同じにする。順序も変えない。",
            "- 内容を要約したり言い換えたりしない。発言の意味は保つ。",
            "- 取り除いた結果が空になる場合は空文字列にする。",
        ]

        if !glossary.terms.isEmpty {
            lines.append("")
            lines.append("次の固有名詞・専門用語が登場します。音が近い誤変換を見つけたら正しい表記に直してください:")
            lines.append(glossary.terms.joined(separator: "、"))
        }

        return lines.joined(separator: "\n")
    }

    /// 要約レポート。既存の meeting-notes スキルと同じ体裁に揃えてある。
    ///
    /// - Parameters:
    ///   - participants: 登場人物。人名の正解表記として渡す。
    ///   - hasMemo: 入力に人が書いたメモが含まれるか。
    public static func summarize(
        title: String,
        date: String,
        duration: String,
        participants: [String] = [],
        hasMemo: Bool = false
    ) -> String {
        var rules = [
            "- 出力は Markdown のみ。前置きも説明もコードフェンスも付けない。",
            "- 文字起こしに書かれていないことを推測で補わない。",
            "- 引用が必要な箇所は文字起こしのタイムスタンプ [mm:ss] を併記する。",
            "- 固有名詞や専門用語は誤変換の可能性があるので、文脈から補正して書く。",
            "- 該当する内容が無い節は「特になし」と書く。",
        ]

        if !participants.isEmpty {
            rules.append(
                "- 登場人物は次の表記に揃える: \(participants.joined(separator: "、"))。"
                    + "音が近い誤変換（例: 姓の当て字違い）はこの表記に直す。")
            rules.append("- 担当者はこの中から特定できる場合のみ書き、断定できないときは空欄にする。")
        }

        if hasMemo {
            rules.append(
                "- 入力の「## 会議メモ（人が書いた補足）」は、その場で人が書き留めた一次情報。"
                    + "文字起こしと食い違う場合はメモを優先し、メモにしかない決定事項・宿題も必ず反映する。")
            rules.append("- ただしメモにも文字起こしにも無いことは書かない。")
        }

        // 補間した文字列は複数行リテラルのインデント除去の対象外なので、
        // 行頭に空白を入れるとそのまま出て Markdown のコードブロックになる。
        let participantLine = participants.isEmpty
            ? "" : "\n- 登場人物: \(participants.joined(separator: "、"))"

        return """
            入力は会議の記録です。以下の Markdown テンプレートに沿って、\
            実務で経緯を追える粒度の要約レポートを作成してください。

            厳守事項:
            \(rules.joined(separator: "\n"))

            テンプレート:

            # \(title) 要約レポート

            - 実施日: \(date)
            - 長さ: \(duration)\(participantLine)

            ## 会議概要

            （全体の要旨を数行で）

            ## 決定事項

            - （確定・合意した事項を箇条書き）

            ## アクションアイテム

            | 内容 | 担当 | 期限 |
            |---|---|---|
            | | | |

            ## 議論の要点

            ### <トピック>
            - 要点（必要に応じ [mm:ss] で原典参照）
            """
    }
}
