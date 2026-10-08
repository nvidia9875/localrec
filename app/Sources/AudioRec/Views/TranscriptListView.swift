import AudioRecKit
import SwiftUI

/// 文字起こし本文。Notion の会議ノートと同じく
/// 「左に固定幅のタイムスタンプ列 → 話者チップ → 本文」の 3 カラム。
struct TranscriptListView: View {
    let transcript: Transcript
    var playbackTime: TimeInterval? = nil
    var volatileText: String? = nil
    var onSeek: ((TimeInterval) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcript.segments) { segment in
                    TranscriptRow(
                        segment: segment,
                        isPlaying: isPlaying(segment),
                        onSeek: onSeek
                    )
                    .id(segment.id)
                }

                if let volatileText, !volatileText.isEmpty {
                    VolatileRow(text: volatileText)
                }
            }
            .frame(maxWidth: Theme.Metrics.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.contentPadding - Theme.Metrics.rowHorizontalInset)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if transcript.isEmpty && (volatileText ?? "").isEmpty {
                emptyState
            }
        }
    }

    private func isPlaying(_ segment: TranscriptSegment) -> Bool {
        guard let playbackTime else { return false }
        return playbackTime >= segment.start && playbackTime < segment.end
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("まだ文字起こしがありません")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 1 行

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let isPlaying: Bool
    let onSeek: ((TimeInterval) -> Void)?

    @State private var isHovering = false

    /// これを下回る信頼度の発話には点線下線を引き、修正候補であることを示す。
    private static let lowConfidenceThreshold = 0.55

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            timestamp
            if segment.speaker != .unknown {
                SpeakerChip(speaker: segment.speaker)
            }
            text
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metrics.rowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.rowHorizontalInset)
        .background(isPlaying ? Theme.Palette.highlight : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// hover で再生ボタンに変わる。クリックでその位置にシークする。
    private var timestamp: some View {
        Button {
            onSeek?(segment.start)
        } label: {
            Group {
                if isHovering && onSeek != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                } else {
                    Text(TimeCode.short(segment.start))
                        .font(Theme.Font.timestamp)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.Palette.textMuted)
            .frame(width: Theme.Metrics.timestampColumnWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(onSeek == nil)
    }

    private var text: some View {
        Text(segment.text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.text)
            .lineSpacing(Theme.Metrics.bodyLineSpacing)
            .textSelection(.enabled)
            .underline(isLowConfidence, pattern: .dot, color: Theme.Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isLowConfidence: Bool {
        guard let confidence = segment.confidence, !segment.edited else { return false }
        return confidence < Self.lowConfidenceThreshold
    }
}

// MARK: - 未確定行

/// エンジンがまだ確定していない (volatile) テキスト。
/// 薄い色で出し、確定したら通常行に置き換わる。
private struct VolatileRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Color.clear.frame(width: Theme.Metrics.timestampColumnWidth, height: 1)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textVolatile)
                .lineSpacing(Theme.Metrics.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Metrics.rowVerticalPadding)
        .padding(.horizontal, Theme.Metrics.rowHorizontalInset)
    }
}

// MARK: - 話者チップ

struct SpeakerChip: View {
    let speaker: SpeakerRole

    var body: some View {
        Text(speaker.displayName)
            .font(Theme.Font.speakerChip)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .fixedSize()
    }

    private var foreground: Color {
        switch speaker {
        case .mySelf: Theme.Palette.speakerSelfFG
        case .other: Theme.Palette.speakerOtherFG
        case .unknown: Theme.Palette.textMuted
        }
    }

    private var background: Color {
        switch speaker {
        case .mySelf: Theme.Palette.speakerSelfBG
        case .other: Theme.Palette.speakerOtherBG
        case .unknown: Theme.Palette.surfaceHover
        }
    }
}
