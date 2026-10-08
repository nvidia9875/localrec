import AudioRecKit
import SwiftUI

/// 要約レポートを表示する。まだ無ければ生成ボタンを出す。
struct SummaryPaneView: View {
    @Bindable var model: AppModel
    let recording: Recording

    var body: some View {
        Group {
            if model.isSummarizing {
                progress
            } else if let summary = model.summary, !summary.isEmpty {
                MarkdownView(markdown: summary)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progress: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("要約を作成しています…")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)
            Text("claude -p を実行中")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text("要約はまだ作られていません")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)

            Button {
                Task { await model.generateSummary() }
            } label: {
                Text("要約を作成")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                            .stroke(Theme.Palette.rule, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGenerateSummary)

            Text(hint)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 何を材料に作るのかを常に見せる。メモが混ざることを後から気付かせない。
    private var hint: String {
        if !model.canGenerateSummary {
            return "文字起こしもメモも無いため作成できません"
        }
        if recording.transcript.isEmpty {
            return "メモの内容から作成します"
        }
        return model.memoDraft.isEmpty
            ? "文字起こしから作成します"
            : "文字起こしとメモの両方から作成します"
    }
}

// MARK: - Markdown 描画

/// 要約に必要な範囲だけを描く。
/// SwiftUI の Markdown サポートはインライン記法止まりで、
/// 見出しも表も平文になってしまうため。
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))
                .foregroundStyle(Theme.Palette.text)
                .padding(.top, level == 1 ? 0 : 20)
                .padding(.bottom, 8)

        case .paragraph(let text):
            Text(.init(text))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.text)
                .lineSpacing(Theme.Metrics.bodyLineSpacing)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.Palette.textMuted)
                Text(.init(text))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.text)
                    .lineSpacing(Theme.Metrics.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .divider:
            Rectangle()
                .fill(Theme.Palette.rule)
                .frame(height: 1)
                .padding(.vertical, 14)
        }
    }

    private func tableView(header: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tableRow(header, isHeader: true)
            Rectangle().fill(Theme.Palette.rule).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                tableRow(row, isHeader: false)
                Rectangle().fill(Theme.Palette.rule).frame(height: 1)
            }
        }
        .padding(.bottom, 14)
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(.init(cell))
                    .font(.system(size: 14, weight: isHeader ? .medium : .regular))
                    .foregroundStyle(isHeader ? Theme.Palette.textMuted : Theme.Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 24
        case 2: 18
        default: 15
        }
    }
}
