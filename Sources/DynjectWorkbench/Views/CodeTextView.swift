import AppKit
import SwiftUI

/// A plain monospaced text editor with every "smart" substitution turned off, so config and XML
/// text is never altered behind the user's back.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var identifier: String
    var isEditable = true
    /// 0-based line to highlight (e.g. a diagnostic), if any.
    var highlightLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isEditable = isEditable
        tv.string = text
        tv.setAccessibilityIdentifier(identifier)
        scroll.setAccessibilityIdentifier(identifier + "-scroll")
        scroll.hasHorizontalScroller = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        context.coordinator.parent = self
        tv.isEditable = isEditable
        if tv.string != text {
            let selection = tv.selectedRanges
            tv.string = text
            let length = (text as NSString).length
            tv.selectedRanges = selection.map { r in
                let range = r.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
        }
        applyHighlight(tv)
    }

    private func applyHighlight(_ tv: NSTextView) {
        guard let storage = tv.textStorage, let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard let line = highlightLine else { return }
        let ns = tv.string as NSString
        var index = 0, current = 0
        while current < line, index < ns.length {
            let r = ns.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(r)
            current += 1
        }
        guard index <= ns.length else { return }
        let r = ns.lineRange(for: NSRange(location: index, length: 0))
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: r)
        tv.scrollRangeToVisible(r)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
