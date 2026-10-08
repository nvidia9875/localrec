import AudioRecKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    /// 名前を変更中の録音。一覧の行をその場で書き換える。
    @State private var renamingID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().overlay(Theme.Palette.rule)
            if model.searchHits.isEmpty {
                recordingList
            } else {
                searchResults
            }
        }
        .background(Theme.Palette.sidebar)
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: 6) {
            Text("録音")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.text)
            Text("\(model.recordings.count)")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
                .monospacedDigit()
            Spacer()
            enginePicker
            recordButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 文字起こしエンジンと録音範囲の切り替え。録音中は変えられない。
    private var enginePicker: some View {
        Menu {
            Section("文字起こしエンジン") {
                ForEach(ASREngineKind.allCases, id: \.self) { kind in
                    Button {
                        model.engineKind = kind
                    } label: {
                        Text(kind.displayName)
                        if model.engineKind == kind { Image(systemName: "checkmark") }
                    }
                }
            }
            Section("録音する音声") {
                Button {
                    model.captureSystemAudio.toggle()
                } label: {
                    Text("システム音声も録る（相手の声）")
                    if model.captureSystemAudio { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRecording)
        .help("文字起こしエンジン: \(model.engineKind.displayName)")
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 10))
                Text(model.isRecording ? "停止" : "録音")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.Palette.recording)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help(model.isRecording ? "録音を停止 (⌘R)" : "録音を開始 (⌘R)")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textMuted)
            TextField("検索", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.text)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.Palette.surfaceHover)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - 一覧

    private var recordingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groupedRecordings, id: \.title) { group in
                    Section {
                        ForEach(group.items) { meta in
                            SidebarRow(
                                meta: meta,
                                isSelected: model.selectedID == meta.id,
                                isRenaming: renamingID == meta.id,
                                onRename: { title in
                                    renamingID = nil
                                    Task { await model.rename(meta.id, to: title) }
                                },
                                onCancelRename: { renamingID = nil }
                            )
                            .onTapGesture { model.selectedID = meta.id }
                            .contextMenu {
                                Button("名前を変更") { renamingID = meta.id }
                                Button("Finder で表示") { model.revealInFinder(meta.id) }
                                Divider()
                                Button("削除", role: .destructive) {
                                    Task { await model.delete(meta.id) }
                                }
                            }
                        }
                    } header: {
                        sectionHeader(group.title)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if model.filteredRecordings.isEmpty {
                emptyState
            }
        }
    }

    /// 検索結果。録音を横断して、ヒットした発話そのものを並べる。
    /// 録音名だけを出すより、目的の箇所へ直接飛べる方が実用的。
    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("\(model.searchHits.count) 件の発話")
                ForEach(model.searchHits) { hit in
                    SearchHitRow(hit: hit)
                        .onTapGesture { Task { await model.jump(to: hit) } }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Font.sectionHeader)
            .foregroundStyle(Theme.Palette.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(Theme.Palette.sidebar)
    }

    private var emptyState: some View {
        Text(model.searchText.isEmpty ? "まだ録音がありません" : "見つかりません")
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.textMuted)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 検索結果の行

private struct SearchHitRow: View {
    let hit: SearchHit

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(hit.recordingTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
                Text(TimeCode.short(hit.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            HStack(alignment: .top, spacing: 5) {
                if hit.speaker != .unknown {
                    SpeakerChip(speaker: hit.speaker)
                }
                Text(hit.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - 行

private struct SidebarRow: View {
    let meta: RecordingMeta
    let isSelected: Bool
    var isRenaming = false
    var onRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    @State private var isHovering = false
    @State private var draftTitle = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isRenaming {
                titleField
            } else {
                Text(meta.title)
                    .font(Theme.Font.sidebarItem)
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: meta.createdAt))
                Text("·")
                Text(TimeCode.duration(meta.duration))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.Palette.textMuted)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftTitle = meta.title
                isFieldFocused = true
            }
        }
    }

    /// 行の中でそのまま書き換える。Enter で確定、Esc で取り消し。
    private var titleField: some View {
        TextField("無題", text: $draftTitle)
            .textFieldStyle(.plain)
            .font(Theme.Font.sidebarItem)
            .foregroundStyle(Theme.Palette.text)
            .focused($isFieldFocused)
            .onSubmit { onRename(draftTitle) }
            .onExitCommand { onCancelRename() }
            .onChange(of: isFieldFocused) { _, focused in
                // 他をクリックして離れたときも、打った名前を捨てない
                if !focused, isRenaming { onRename(draftTitle) }
            }
            .onAppear {
                draftTitle = meta.title
                isFieldFocused = true
            }
    }

    private var rowBackground: Color {
        if isSelected { return Theme.Palette.surfaceSelected }
        if isHovering { return Theme.Palette.surfaceHover }
        return .clear
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()
}
