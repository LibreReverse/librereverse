#if os(macOS)
import AppKit

/// Accessory apps do not always have an Edit menu to dispatch standard shortcuts.
/// Keep these commands local to Settings and let its native editor handle edits.
@MainActor
final class LibreReverseSettingsEditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow else { return super.performKeyEquivalent(with: event) }
        return routeEditingCommand(event) || super.performKeyEquivalent(with: event)
    }

    func routeEditingCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.windowNumber == 0 || event.windowNumber == windowNumber,
              let editor = firstResponder as? NSTextView, editor.window === self else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        let secure = isSecureEditor(editor)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v" where modifiers == .command && editor.isEditable:
            editor.paste(nil)
            return true
        case "v" where modifiers == [.command, .shift] && editor.isEditable:
            editor.pasteAsPlainText(nil)
            return true
        case "a" where modifiers == .command && editor.isSelectable:
            editor.selectAll(nil)
            return true
        case "c" where modifiers == .command:
            // Consume the command: falling through could let a menu handler
            // bypass the secure field's clipboard restrictions.
            if secure { return true }
            guard editor.isSelectable else { return false }
            editor.copy(nil)
            return true
        case "x" where modifiers == .command:
            if secure { return true }
            guard editor.isEditable else { return false }
            editor.cut(nil)
            return true
        case "z" where editor.isEditable:
            if modifiers == [.command, .shift] { editor.undoManager?.redo() }
            else { editor.undoManager?.undo() }
            return true
        default:
            return false
        }
    }

    func isSecureEditor(_ editor: NSTextView) -> Bool {
        if editor.delegate is NSSecureTextField { return true }
        // AppKit may supply an internal delegate for its shared field editor.
        // Match the owning control rather than inspecting or copying its value.
        func containsOwner(_ view: NSView) -> Bool {
            if let field = view as? NSSecureTextField, field.currentEditor() === editor { return true }
            return view.subviews.contains(where: containsOwner)
        }
        return contentView.map(containsOwner) ?? false
    }
}
#endif
