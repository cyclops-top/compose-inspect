import AppKit
import ComposeInspectCore
import SwiftUI

/// NSTextView keeps IME composition local. Only committed text is recorded in the ledger.
struct ComponentTextEditor: NSViewRepresentable {
    let component: ComponentKey
    let text: String
    let onChange: (String, ComponentKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(component: component, onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = PromptTextView(frame: .zero)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        editor.delegate = context.coordinator
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.setAccessibilityLabel("当前组件的问题描述，留空不记录")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if coordinator.component != component {
            // WorkspaceStore.select resigns the editor before changing components.
            // Do not mutate observable state during a SwiftUI view update.
            coordinator.component = component
            coordinator.onChange = onChange
            coordinator.replacing = true
            editor.string = text
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.replacing = false
        } else {
            coordinator.onChange = onChange
            if !editor.hasMarkedText(), editor.string != text {
                coordinator.replacing = true
                editor.string = text
                coordinator.replacing = false
            }
        }
        editor.needsDisplay = true
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var component: ComponentKey
        var onChange: (String, ComponentKey) -> Void
        var replacing = false
        init(component: ComponentKey, onChange: @escaping (String, ComponentKey) -> Void) {
            self.component = component; self.onChange = onChange
        }
        func textDidChange(_ notification: Notification) {
            guard !replacing, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            onChange(editor.string, component)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard !replacing, let editor = notification.object as? NSTextView else { return }
            if editor.hasMarkedText() { editor.unmarkText() }
            onChange(editor.string, component)
        }
    }
}

@MainActor private final class PromptTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            ("描述这个组件的问题或期望修改…" as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
        }
    }
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
