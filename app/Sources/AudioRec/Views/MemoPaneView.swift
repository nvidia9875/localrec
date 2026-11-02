import AudioRecKit
import SwiftUI

/// 人が書くメモ。会議中の気づきや、音声に残らない決定を書き留める場所。
///
/// ここに書いた内容は `memo.md` として録音と同じディレクトリに保存され、
/// サマリー生成のときに文字起こしと一緒に claude へ渡る。
struct MemoPaneView: View {
    @Bindable var model: AppModel
    let recording: Recording

    private static let placeholder = """
        決まったこと、宿題、音声に残らなかった前提などを書きます。
        Markdown で書けます（# 見出し、- 箇条書き、- [ ] 宿題、**太字**）。
        サマリーを作るときに文字起こしと一緒に渡されます。
        """

    var body: some View {
        VStack(spacing: 0) {
            editor
            Divider().overlay(Theme.Palette.rule)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 上下の余白はエディタの内側に持たせる（スクロールしたときに本文が枠で切れないように）。
    private var editor: some View {
        MarkdownMemoEditor(text: $model.memoDraft, placeholder: Self.placeholder)
            .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.isMemoSaved ? "保存済み" : "編集中…")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
            Text("Markdown")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
                .help("# 見出し、- 箇条書き、- [ ] 宿題、**太字**、`コード` が使えます。memo.md にそのまま保存されます")
            Spacer()
            summarizeButton
        }
        .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// メモを材料にレポートを作る。既にサマリーがあれば作り直しになる。
    private var summarizeButton: some View {
        Button {
            Task { await model.summarizeFromMemo() }
        } label: {
            HStack(spacing: 5) {
                if model.isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 11))
                }
                Text(buttonTitle)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .stroke(Theme.Palette.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isSummarizing || !model.canGenerateSummary)
        .help("メモと文字起こしからサマリーを作ります")
    }

    private var buttonTitle: String {
        if model.isSummarizing { return "作成中…" }
        return model.summary?.isEmpty == false ? "サマリーを作り直す" : "このメモからサマリーを作る"
    }
}
