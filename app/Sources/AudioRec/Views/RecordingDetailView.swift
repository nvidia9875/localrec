import AudioRecKit
import SwiftUI

struct RecordingDetailView: View {
    @Bindable var model: AppModel
    let recording: Recording

    @State private var isTitleHovering = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerArea
            Divider().overlay(Theme.Palette.rule)
            content
        }
    }

    // MARK: - ヘッダ (タイトル・メタ・タブ)

    private var headerArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleField
                .padding(.top, 28)

            metaLine
                .padding(.top, 8)

            ParticipantsView(model: model, recording: recording)
                .padding(.top, 8)

            tabBar
                .padding(.top, 18)
        }
        .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// タイトルはその場で編集する。押せることが分かるよう hover で面を出す。
    ///
    /// 打鍵は少し待ってから自動で保存される (`AppModel.titleDraft`)。
    /// Enter でも確定できるが、押さずに他へ移っても消えない。Esc で元に戻す。
    private var titleField: some View {
        TextField("無題", text: $model.titleDraft)
            .textFieldStyle(.plain)
            .font(Theme.Font.title)
            .foregroundStyle(Theme.Palette.text)
            .focused($isTitleFocused)
            .onSubmit { isTitleFocused = false }
            .onExitCommand { cancelTitleEdit() }
            .onChange(of: isTitleFocused) { _, focused in
                if !focused { Task { await model.flushTitle() } }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(titleBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            // 面の分だけ外へ戻し、本文・メタ行と左端を揃える
            .padding(.horizontal, -6)
            .onHover { isTitleHovering = $0 }
            .help("クリックするとタイトルを変更できます")
    }

    private var titleBackground: Color {
        if isTitleFocused { return Theme.Palette.surfaceSelected }
        if isTitleHovering { return Theme.Palette.surfaceHover }
        return .clear
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(Self.dateFormatter.string(from: recording.meta.createdAt))
            separator
            Text(TimeCode.duration(recording.meta.duration))
            if let engine = recording.meta.engine {
                separator
                Text(engine.displayName)
            }
            if recording.meta.tracks.count > 1 {
                separator
                Text("2トラック")
            }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.Palette.textMuted)
    }

    private var separator: some View {
        Text("·").foregroundStyle(Theme.Palette.textMuted)
    }

    private var tabBar: some View {
        HStack(spacing: 18) {
            ForEach(DetailTab.allCases) { tab in
                TabButton(
                    title: tab.title,
                    isActive: model.detailTab == tab
                ) {
                    model.detailTab = tab
                }
            }
            Spacer()
            switch model.detailTab {
            case .transcript: polishButton
            case .summary: regenerateButton
            case .memo: EmptyView()
            }
            exportMenu
        }
    }

    /// 書き出し。md / srt は保存時に毎回作り直しているので、
    /// ここでは既にあるファイルへ案内するだけでよい。
    private var exportMenu: some View {
        Menu {
            Button("Finder で表示") { model.revealInFinder(recording.id) }
            Divider()
            Button("文字起こしをコピー") { model.copyTranscript(recording) }
            Button("Markdown をコピー") { model.copyMarkdown(recording) }
            if model.summary?.isEmpty == false {
                Button("要約をコピー") { model.copySummary() }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("書き出し")
    }

    /// claude -p でフィラーを取り除き、句読点を整える。
    /// 時刻と話者はそのまま残るので、押しても情報は失われない。
    private var polishButton: some View {
        Button {
            Task { await model.polishTranscript() }
        } label: {
            HStack(spacing: 5) {
                if model.isPolishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wand.and.sparkles").font(.system(size: 11))
                }
                Text(model.isPolishing ? "整形中…" : "整形")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.Palette.textMuted)
        }
        .buttonStyle(.plain)
        .disabled(model.isPolishing || recording.transcript.isEmpty)
        .help("フィラーを取り除いて句読点を整えます（時刻と話者は変わりません）")
    }

    /// サマリーを作り直す。中身を消してから作るので、新旧が混ざらない。
    @ViewBuilder
    private var regenerateButton: some View {
        if model.summary?.isEmpty == false {
            Button {
                Task { await model.regenerateSummary() }
            } label: {
                HStack(spacing: 5) {
                    if model.isSummarizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    Text(model.isSummarizing ? "作成中…" : "再生成")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(model.isSummarizing)
            .help("いまの要約を消して、もう一度作り直します")
        }
    }

    // MARK: - 本文

    @ViewBuilder
    private var content: some View {
        switch model.detailTab {
        case .transcript:
            // 録音中はセッションが持つ進行中の文字起こしを見せる。
            // 保存済みの transcript を読み直すと、行が出るまで数秒遅れる。
            if isLive {
                TranscriptListView(
                    transcript: model.session.liveTranscript,
                    volatileText: model.session.volatileText
                )
            } else {
                TranscriptListView(
                    transcript: recording.transcript,
                    playbackTime: model.playback.duration > 0 ? model.playback.currentTime : nil,
                    onSeek: { time in
                        model.playback.seek(to: time)
                        model.playback.play()
                    }
                )
            }
        case .memo:
            MemoPaneView(model: model, recording: recording)
        case .summary:
            SummaryPaneView(model: model, recording: recording)
        }
    }

    /// この録音が今まさに録音中か。
    private var isLive: Bool {
        model.session.isRecording && model.session.currentID == recording.id
    }

    private func cancelTitleEdit() {
        model.revertTitle()
        isTitleFocused = false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}

// MARK: - タブボタン

private struct TabButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // 下線でアクティブを示す。Notion と同じく面ではなく線で表現する。
            // Rectangle を VStack に並べると幅を貪欲に取ってしまうので、
            // Text の overlay として重ね、下線幅を文字幅にぴったり合わせる。
            Text(title)
                .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.Palette.text : Theme.Palette.textMuted)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isActive ? Theme.Palette.text : .clear)
                        .frame(height: 2)
                }
                .opacity(isHovering && !isActive ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

