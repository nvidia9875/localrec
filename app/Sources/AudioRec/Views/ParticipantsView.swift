import AudioRecKit
import SwiftUI

/// 登場人物の名前。タイトルの下に並べる。
///
/// 人名は文字起こしで最も誤変換されやすい一方、正解は人しか知らない。
/// ここで入れた表記を整形と要約のヒントとして claude に渡す。
struct ParticipantsView: View {
    @Bindable var model: AppModel
    let recording: Recording

    @State private var isAdding = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textMuted)

            ForEach(recording.meta.participants, id: \.self) { name in
                ParticipantChip(name: name) {
                    Task { await model.removeParticipant(name, from: recording) }
                }
            }

            if isAdding {
                field
            } else {
                addButton
            }
            Spacer(minLength: 0)
        }
        .onChange(of: recording.id) { _, _ in
            isAdding = false
            draft = ""
        }
    }

    private var field: some View {
        TextField("名前（「、」区切りでまとめて）", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.text)
            .frame(width: 200)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.Palette.surfaceHover)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .focused($isFieldFocused)
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: isFieldFocused) { _, focused in
                // 別の場所をクリックして離れたときも、打った名前は捨てない
                if !focused { commit() }
            }
            .onAppear { isFieldFocused = true }
    }

    private var addButton: some View {
        Button {
            isAdding = true
        } label: {
            Text(recording.meta.participants.isEmpty ? "＋ 登場人物" : "＋")
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("会議に出ている人の名前を足します（要約の人名表記に使われます）")
    }

    private func commit() {
        let input = draft
        draft = ""
        isAdding = false
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await model.addParticipants(input, to: recording) }
    }

    private func cancel() {
        draft = ""
        isAdding = false
    }
}

// MARK: - チップ

/// 名前 1 件。hover で削除ボタンが出る。
private struct ParticipantChip: View {
    let name: String
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.text)
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("この人を外す")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.Palette.surfaceHover)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .fixedSize()
        .onHover { isHovering = $0 }
    }
}
