import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class SettingsEditingWindowTests: XCTestCase {
    private final class SecureOwner: NSSecureTextField, NSTextViewDelegate {}
    private final class Editor: NSTextView {
        var pasteCalls = 0
        var plainPasteCalls = 0
        var copyCalls = 0
        var cutCalls = 0
        override func paste(_ sender: Any?) { pasteCalls += 1 }
        override func pasteAsPlainText(_ sender: Any?) { plainPasteCalls += 1 }
        override func copy(_ sender: Any?) { copyCalls += 1 }
        override func cut(_ sender: Any?) { cutCalls += 1 }
    }
    private func event(_ key: String, window: NSWindow, shift: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 9))
    }
    private func fixture() -> (LibreReverseSettingsEditingWindow, Editor) {
        _ = NSApplication.shared
        let window = LibreReverseSettingsEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let editor = Editor(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        editor.string = "Synthetic field value"
        editor.isEditable = true
        editor.isSelectable = true
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        return (window, editor)
    }

    func testNormalConfigurationEditorReceivesNativeEditingCommands() throws {
        let (window, editor) = fixture()
        XCTAssertTrue(window.routeEditingCommand(try event("v", window: window)))
        XCTAssertTrue(window.routeEditingCommand(try event("v", window: window, shift: true)))
        XCTAssertEqual(editor.pasteCalls, 1)
        XCTAssertEqual(editor.plainPasteCalls, 1)
        XCTAssertTrue(window.routeEditingCommand(try event("a", window: window)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertTrue(window.routeEditingCommand(try event("c", window: window)))
        XCTAssertTrue(window.routeEditingCommand(try event("x", window: window)))
        XCTAssertEqual(editor.copyCalls, 1)
        XCTAssertEqual(editor.cutCalls, 1)
        XCTAssertFalse(window.routeEditingCommand(try event("q", window: window)))
    }

    func testSecureEditorAcceptsPasteButNeverDispatchesCopyOrCut() throws {
        let (window, editor) = fixture()
        let secure = SecureOwner()
        defer { withExtendedLifetime(secure) {} }
        editor.delegate = secure
        XCTAssertTrue(window.isSecureEditor(editor))
        XCTAssertTrue(window.routeEditingCommand(try event("v", window: window)))
        XCTAssertEqual(editor.pasteCalls, 1)
        XCTAssertTrue(window.routeEditingCommand(try event("a", window: window)))
        let selection = editor.selectedRange()
        XCTAssertTrue(window.routeEditingCommand(try event("c", window: window)))
        XCTAssertTrue(window.routeEditingCommand(try event("x", window: window)))
        XCTAssertEqual(editor.copyCalls, 0)
        XCTAssertEqual(editor.cutCalls, 0)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, "Synthetic field value")
    }

    func testActualSecureFieldEditorIsRecognizedWithoutReadingItsValue() throws {
        _ = NSApplication.shared
        let window = LibreReverseSettingsEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 40, width: 300, height: 24))
        window.contentView?.addSubview(secure)
        secure.selectText(nil)
        let editor = try XCTUnwrap(secure.currentEditor() as? NSTextView)
        XCTAssertTrue(window.isSecureEditor(editor))
        XCTAssertTrue(window.routeEditingCommand(try event("c", window: window)))
        XCTAssertTrue(window.routeEditingCommand(try event("x", window: window)))
    }

    func testForeignWindowAndNoneditablePasteAreNotIntercepted() throws {
        let (window, editor) = fixture()
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        XCTAssertFalse(window.routeEditingCommand(try event("v", window: other)))
        editor.isEditable = false
        XCTAssertFalse(window.routeEditingCommand(try event("v", window: window)))
        XCTAssertEqual(editor.pasteCalls, 0)
    }
}
