import AppKit
import SwiftUI

/// The message field: a native text view that grows with its text up to a few
/// lines and then scrolls, with WhatsApp's keys (↩ sends, ⇧↩ / ⌥↩ start a new
/// line). SwiftUI's own multi-line text field could not be scrolled once the
/// text outgrew it.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// The height the text needs, capped at `maxLines`; the field sizes itself to it.
    @Binding var height: CGFloat
    /// Bumped to put the caret in the field.
    var focusRequest: Int
    var maxLines = 8
    var onSubmit: () -> Void
    /// Each returns whether it used the key.
    var onEscape: () -> Bool = { false }
    var onUpArrow: () -> Bool = { false }
    var onDownArrow: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    /// Asked before ↩ sends; true takes the key (a suggestion was picked).
    var interceptReturn: () -> Bool = { false }

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let textView = PlaceholderTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.drawsBackground = false
        // Spelling as in Mail and Messages; the automatic quotes and dashes
        // stay off, as they would get into code and markup.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        textView.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 4
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        // Dropped files belong to the chat (it attaches them), not here as paths.
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.string])
        textView.string = text
        textView.placeholder = placeholder
        scroll.documentView = textView

        // Wrapping changes with the width, and so does the height needed.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollToEndOfDocument(nil)
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                guard let window = textView.window, window.firstResponder !== textView else { return }
                window.makeFirstResponder(textView)
            }
        }
        coordinator.measure()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: PlaceholderTextView?
        var focusRequest: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusRequest = parent.focusRequest - 1
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            measure()
        }

        @objc func frameChanged() { measure() }

        /// Works out how tall the field should be for its text.
        func measure() {
            guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
            manager.ensureLayout(for: container)
            // Shrink back as well as grow, so there is no blank space to scroll into.
            textView.sizeToFit()
            let line = ceil(manager.defaultLineHeight(for: ComposerTextView.font))
            let used = ceil(manager.usedRect(for: container).height)
            let target = min(max(used, line), line * CGFloat(parent.maxLines))
            guard abs(target - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.height = target }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Keys that finish an input method's composition are not ours.
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // ⇧↩ / ⌥↩ never get here; see PlaceholderTextView.keyDown.
                if parent.interceptReturn() { return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onUpArrow()
            case #selector(NSResponder.moveDown(_:)):
                return parent.onDownArrow()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            default:
                return false
            }
        }
    }
}

/// A text view that shows a grey hint while it is empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? ComposerTextView.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        placeholder.draw(at: NSPoint(x: x, y: textContainerOrigin.y), withAttributes: attributes)
    }

    /// ⇧↩ and ⌥↩ break the line, read from the key itself rather than from
    /// whatever event the app saw last.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(), !flags.intersection([.shift, .option]).isEmpty {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}
