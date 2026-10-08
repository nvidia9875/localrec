import AppKit
import AudioRecKit
import SwiftUI

/// 録音中に本文の上に居座るバー。Notion の録音バーと同じ位置づけ。
struct RecordBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            recordingIndicator
            elapsed
            if let progress = model.session.modelDownloadProgress {
                downloadIndicator(progress)
            } else if model.session.isSaving {
                statusText("保存しています…", showsProgress: true)
            } else if model.session.isPaused {
                statusText("一時停止中", showsProgress: false)
            } else {
                WaveformView(levels: model.session.levels)
                    .frame(maxWidth: .infinity)
            }
            pauseButton
            stopButton
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 12)
        .background(Theme.Palette.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Palette.rule).frame(height: 1)
        }
    }

    /// 録っている間だけ赤く点滅させる。止めている間に点滅していると、録れていると誤解する。
    @ViewBuilder
    private var recordingIndicator: some View {
        if model.session.isPaused || model.session.isSaving {
            Circle()
                .fill(Theme.Palette.textMuted)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(Theme.Palette.recording)
                .frame(width: 8, height: 8)
                .modifier(PulseEffect())
        }
    }

    private func statusText(_ text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var elapsed: some View {
        Text(TimeCode.short(model.session.elapsed))
            .font(Theme.Font.timestamp)
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.text)
    }

    /// 初回だけ発生する音声認識モデルのダウンロード。数百 MB あるので黙って待たせない。
    private func downloadIndicator(_ progress: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .controlSize(.small)
                .frame(maxWidth: 180)
            Text("音声認識モデルを取得中 \(Int(progress * 100))%")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
                .monospacedDigit()
            Spacer()
        }
    }

    private var pauseButton: some View {
        let isPaused = model.session.isPaused
        return Button {
            model.togglePause()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPaused ? "record.circle" : "pause.fill").font(.system(size: 9))
                Text(isPaused ? "再開" : "一時停止").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Palette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Theme.Palette.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .buttonStyle(.plain)
        .disabled(model.session.isSaving)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(isPaused ? "録音を再開 (⇧⌘P)" : "録音を一時停止 (⇧⌘P)")
    }

    private var stopButton: some View {
        Button {
            Task { await model.stopRecording() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 9))
                Text("停止").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Theme.Palette.recording)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .buttonStyle(.plain)
        .disabled(model.session.isSaving)
        // 開始は詳細ペインの「録音を開始」が同じ ⌘R を持つ。録音中はあちらが消えるので衝突しない
        .keyboardShortcut("r", modifiers: .command)
        .help("録音を停止 (⌘R)")
    }
}

// MARK: - 波形

/// 入力レベルの履歴を縦棒で描く。
/// 左から右に流れ、右端が最新。
struct WaveformView: View {
    let levels: [Float]
    var barCount: Int = 64

    private let barWidth: CGFloat = 3
    private let maxHeight: CGFloat = 24
    private let minHeight: CGFloat = 3

    var body: some View {
        // 各バーを「等分した器」の中央に置く。
        // バー自体の幅を固定にすると右端へ寄った細い帯になり、
        // 逆にバーを伸ばすと太い塊になって波形に見えなくなる。
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Theme.Palette.recording.opacity(level > 0 ? 0.85 : 0.25))
                    .frame(width: barWidth, height: height(for: level))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxHeight, alignment: .center)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    /// 常に barCount 本を描く。まだ履歴が足りない間は左を 0 で埋める。
    /// これをしないと録音開始直後に波形の幅が伸び縮みして落ち着かない。
    private var padded: [Float] {
        let recent = levels.suffix(barCount)
        let padding = Array(repeating: Float(0), count: max(0, barCount - recent.count))
        return padding + Array(recent)
    }

    private func height(for level: Float) -> CGFloat {
        minHeight + CGFloat(level) * (maxHeight - minHeight)
    }
}

// MARK: - 録音中の点滅

/// 「視差効果を減らす」が有効なときはアニメーションしない。
private struct PulseEffect: ViewModifier {
    @State private var isDimmed = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed ? 0.35 : 1.0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isDimmed = true
                }
            }
    }
}
