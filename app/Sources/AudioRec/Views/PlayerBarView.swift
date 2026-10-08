import AudioRecKit
import SwiftUI

/// 本文下端の再生バー。文字起こしの行と再生位置が連動する。
struct PlayerBarView: View {
    @Bindable var playback: PlaybackController

    private static let skipSeconds: TimeInterval = 15
    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 12) {
            playButton
            skipButton(by: -Self.skipSeconds, icon: "gobackward.15")
            skipButton(by: Self.skipSeconds, icon: "goforward.15")
            scrubber
            timeLabel
            rateMenu
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 10)
        .background(Theme.Palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Palette.rule).frame(height: 1)
        }
        .disabled(playback.duration <= 0)
        .opacity(playback.duration <= 0 ? 0.4 : 1.0)
    }

    private var playButton: some View {
        Button {
            playback.togglePlay()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.text)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(playback.isPlaying ? "一時停止" : "再生")
    }

    private func skipButton(by delta: TimeInterval, icon: String) -> some View {
        Button {
            playback.skip(by: delta)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { playback.currentTime },
                set: { playback.seek(to: $0) }
            ),
            in: 0...max(playback.duration, 0.01)
        )
        .controlSize(.mini)
        .tint(Theme.Palette.text)
    }

    private var timeLabel: some View {
        Text("\(TimeCode.short(playback.currentTime)) / \(TimeCode.short(playback.duration))")
            .font(Theme.Font.timestamp)
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.textMuted)
            .fixedSize()
    }

    private var rateMenu: some View {
        Menu {
            ForEach(Self.rates, id: \.self) { rate in
                Button {
                    playback.rate = rate
                } label: {
                    Text(Self.label(for: rate))
                    if playback.rate == rate { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Text(Self.label(for: playback.rate))
                .font(Theme.Font.meta)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private static func label(for rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate)).0x" : String(format: "%.2gx", rate)
    }
}
