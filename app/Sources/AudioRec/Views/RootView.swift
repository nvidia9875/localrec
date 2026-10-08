import AudioRecKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: Theme.Metrics.sidebarMinWidth,
                    ideal: Theme.Metrics.sidebarWidth,
                    max: Theme.Metrics.sidebarMaxWidth
                )
        } detail: {
            DetailView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.Palette.background)
        .task { await model.load() }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}

/// 選択中の録音を表示する右ペイン。
/// 上から「録音バー(録音中のみ) → 本文 → 再生バー」の縦積み。
private struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isRecording {
                RecordBarView(model: model)
            }

            if let recording = model.selectedRecording {
                RecordingDetailView(model: model, recording: recording)
            } else {
                EmptyStateView()
            }

            if !model.isRecording {
                PlayerBarView(playback: model.playback)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text("録音を選ぶか、「新規」で作ってください")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)
            Text("⌘N で新規作成。録音は開いた先で ⌘R")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
