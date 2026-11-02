import AppKit
import AudioRecKit
import SwiftUI

/// Markdown で書けるメモ欄。
///
/// SwiftUI の `TextEditor` は内側の余白を外から知る手段が無く、
/// 上に重ねたプレースホルダーとカーソル位置がずれる。ここでは NSTextView を直接持ち、
/// プレースホルダーも同じ NSTextView の中で本文と同じ起点・同じ段落設定で描く。
///
/// 記法は記号を残したまま見た目にだけ反映する（見出しは大きく、記号は薄く）。
/// 保存されるのは打ったとおりの Markdown なので、`memo.md` の中身は変わらない。
struct MarkdownMemoEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MemoScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = MemoTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: MemoStyle.verticalInset)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = false
        // `--` が em ダッシュに、`"` が全角引用符に化けると Markdown が壊れる
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.insertionPointColor = Theme.NSPalette.text
        textView.typingAttributes = MemoStyle.baseAttributes
        textView.placeholder = NSAttributedString(
            string: placeholder,
            attributes: MemoStyle.baseAttributes.merging([.foregroundColor: Theme.NSPalette.textMuted]) { $1 })

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MemoTextView else { return }
        // 録音を切り替えたときだけ流し込む。入力中に書き戻すとカーソルが飛ぶ。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            textView.needsDisplay = true  // プレースホルダーの出し入れ
        }

        /// 文字が変わるたびに全体を塗り直す。メモは長くても数千字なので部分更新はしない。
        ///
        /// did ではなく will で当てる。この後に走るフォント補完（日本語を含まない
        /// システムフォントから日本語フォントへの代替）より前にしないと、日本語が描かれない。
        func textStorage(
            _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MemoStyle.apply(to: textStorage)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return continueList(in: textView)
        }

        /// 箇条書きの行で改行したら、次の行に同じ記号を出す。
        /// 記号だけの行で改行したら、記号を消して箇条書きを抜ける。
        private func continueList(in textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0, !textView.hasMarkedText() else { return false }

            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            guard let item = MarkdownList.item(in: line),
                selection.location - lineRange.location >= item.prefixLength
            else { return false }

            if item.isEmpty {
                let lineBody = NSRange(location: lineRange.location, length: (line as NSString).length)
                guard textView.shouldChangeText(in: lineBody, replacementString: "") else { return true }
                textView.replaceCharacters(in: lineBody, with: "")
                textView.didChangeText()
                return true
            }

            textView.insertText("\n" + item.nextPrefix, replacementRange: selection)
            return true
        }
    }
}

// MARK: - 見た目

private enum MemoStyle {
    static let bodySize: CGFloat = 16
    static let verticalInset: CGFloat = 20

    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular)

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Theme.Metrics.bodyLineSpacing
        return style
    }()

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: Theme.NSPalette.text,
        .paragraphStyle: paragraph,
    ]

    /// 要約表示（`MarkdownView`）の見出しと同じ大きさにそろえる。
    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 24, weight: .semibold)
        case 2: .systemFont(ofSize: 18, weight: .semibold)
        default: .systemFont(ofSize: bodySize, weight: .semibold)
        }
    }

    /// 文字そのものには触らず、属性だけを当て直す。
    /// 変換中の文字（下線つきの未確定文字列）の属性を消さないよう setAttributes は使わない。
    static func apply(to storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.addAttributes(baseAttributes, range: whole)
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.removeAttribute(.strikethroughStyle, range: whole)

        for span in MarkdownSyntax.spans(in: storage.string) {
            switch span.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: headingFont(level: level), range: span.range)
            case .strong:
                let current = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont
                let bold = NSFontManager.shared.convert(current ?? bodyFont, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: span.range)
            case .code:
                storage.addAttributes(
                    [.font: codeFont, .backgroundColor: Theme.NSPalette.surfaceHover], range: span.range)
            case .quote, .checked:
                storage.addAttribute(.foregroundColor, value: Theme.NSPalette.textMuted, range: span.range)
                if span.kind == .checked {
                    storage.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
                }
            case .marker:
                storage.addAttribute(.foregroundColor, value: Theme.NSPalette.textMuted, range: span.range)
            }
        }
    }
}

// MARK: - AppKit ビュー

/// 本文が空のとき、本文と同じ位置にプレースホルダーを描く NSTextView。
final class MemoTextView: NSTextView {
    var placeholder: NSAttributedString?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: origin.x + padding, y: origin.y,
            width: bounds.width - (origin.x + padding) * 2,
            height: bounds.height - origin.y)
        placeholder.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

/// 本文が短くても NSTextView を枠いっぱいに広げる。
/// こうしないと、本文の下の余白をクリックしてもメモ欄に入力できない。
private final class MemoScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        guard textView.minSize.height != height else { return }
        textView.minSize = NSSize(width: 0, height: height)
        if textView.frame.height < height {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
        }
    }
}
