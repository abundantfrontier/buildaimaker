import AppKit
import SwiftUI

/// AppKit-backed multi-line text editor for macOS.
/// SwiftUI `TextEditor` inside sheets/ScrollViews often never becomes first responder.
struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 140
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))

        scroll.documentView = textView
        context.coordinator.textView = textView

        // Become first responder after the sheet/window is up.
        DispatchQueue.main.async {
            scroll.window?.makeFirstResponder(textView)
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let maxLoc = (text as NSString).length
            let loc = min(selected.location, maxLoc)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
        }
        textView.font = font
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor
        weak var textView: NSTextView?

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
