import AudioRecKit
import SwiftUI

/// 人が書くメモ。会議中の気づきや、音声に残らない決定を書き留める場所。
///
/// ここに書いた内容は `memo.md` として録音と同じディレクトリに保存され、
/// サマリー生成のときに文字起こしと一緒に claude へ渡る。
struct MemoPaneView: View {
    @Bindable var model: AppModel
    let recording: Recording

    /// テキストエディタが内部に持つ余白。本文の左端を他タブと揃えるために差し引く。
    private static let editorInset: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            editor
            Divider().overlay(Theme.Palette.rule)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        TextEditor(text: $model.memoDraft)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.text)
            .lineSpacing(Theme.Metrics.bodyLineSpacing)
            .overlay(alignment: .topLeading) { placeholder }
            .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.contentPadding - Self.editorInset)
            .padding(.vertical, 20 - Self.editorInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.memoDraft.isEmpty {
            Text("決まったこと、宿題、音声に残らなかった前提などを書きます。\nサマリーを作るときに文字起こしと一緒に渡されます。")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .lineSpacing(Theme.Metrics.bodyLineSpacing)
                .padding(.top, 8)
                .padding(.leading, Self.editorInset)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.isMemoSaved ? "保存済み" : "編集中…")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
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
