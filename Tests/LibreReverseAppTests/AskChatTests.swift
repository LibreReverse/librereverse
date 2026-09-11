import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class AskChatTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func fixture() -> LibreReverseAskWindowController {
        _ = NSApplication.shared
        return LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in })
    }
    func testMessageViewUsesTextViewDesignatedInitializerAndMeasuresFullText() {
        _ = NSApplication.shared
        let view = LibreReverseAskMessageText(text: "First line\nSecond line", identifier: "synthetic.message")
        view.measure(width: 400)
        XCTAssertEqual(view.string, "First line\nSecond line")
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 24)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
    }

    func testTurnsRetainTheirOwnCitationsAndComposerAndNewChatResets() throws {
        _ = NSApplication.shared
        var opened: [Date] = []
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { opened.append($0) })
        let first = LibreReverseAskCitation(instant: Date(timeIntervalSince1970: 1_700_000_001), title: "First meeting", excerpt: "First evidence", source: "Meeting", evidence: String(repeating: "private synthetic transcript", count: 100))
        let second = LibreReverseAskCitation(instant: Date(timeIntervalSince1970: 1_700_000_002), title: "Second meeting", excerpt: "Second evidence", source: "Meeting")
        controller.presentFixture(question: "First question", answer: .init(text: "First answer [1]", citations: [first]))
        controller.appendFixture(question: "Follow-up question", answer: .init(text: "Second answer [1]", citations: [second]))
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let turns = descendants(content).compactMap { $0 as? LibreReverseAskAnswerView }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map { $0.answer.text }, ["First answer [1]", "Second answer [1]"])
        XCTAssertNil(turns[0].answer.citations[0].evidence, "Do not retain full transcripts for display history")
        for turn in turns {
            let source = try XCTUnwrap(descendants(turn).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "ask.source.1" })
            source.performClick(nil)
        }
        XCTAssertEqual(opened, [first.instant, second.instant])
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "ask.question" })
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(composer.isEditable)
        let newChat = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "ask.new-chat" })
        newChat.performClick(nil)
        XCTAssertEqual(controller.fixtureConversationCount, 0)
        XCTAssertFalse(descendants(content).contains { $0 is LibreReverseAskAnswerView })
        XCTAssertEqual(composer.string, "")
    }

    private actor HistoryRecorder {
        var turns: [LibreReverseAskConversationTurn] = []
        func answer(_ history: [LibreReverseAskConversationTurn]) -> LibreReverseAskAnswer {
            turns = history
            return .init(text: "Continued synthetic answer", citations: [])
        }
        func history() -> [LibreReverseAskConversationTurn] { turns }
    }
    func testFollowupUsesOnlyLastSixCompletedTurnsAndKeepsOlderVisible() async throws {
        let recorder = HistoryRecorder()
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in
            XCTFail("Conversation handler must take precedence")
            return .init(text: "", citations: [])
        }, loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in },
        conversationAnswerHandler: { _, _, turns, _, _ in await recorder.answer(turns) })
        for index in 0..<8 {
            controller.appendFixture(question: "Question \(index)", answer: .init(text: "Answer \(index)", citations: []))
        }
        let task = try XCTUnwrap(controller.requestAnswer(question: "What happened next?"))
        await task.value
        let history = await recorder.history()
        XCTAssertEqual(history.map(\.question), (2..<8).map { "Question \($0)" })
        XCTAssertEqual(controller.fixtureConversationCount, 6)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertEqual(descendants(content).filter { $0 is LibreReverseAskAnswerView }.count, 9)
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "ask.question" })
        XCTAssertEqual(composer.string, "")
        XCTAssertTrue(composer.isEditable)
    }

    func testCommandCopyUsesOnlySelectedRenderedTextAndDoesNotOverwriteWithoutSelection() throws {
        let controller = fixture()
        controller.presentFixture(question: "Synthetic", answer: .init(text: "First sentence. Selected words. Last sentence.", citations: []))
        let window = try XCTUnwrap(controller.window as? LibreReverseAskChatWindow)
        let content = try XCTUnwrap(window.contentView)
        let text = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "ask.answer" })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        window.selectionPasteboard = pasteboard
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setSelectedRange((text.string as NSString).range(of: "Selected words"))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(window.routeTextCommand(event))
        XCTAssertEqual(pasteboard.string(forType: .string), "Selected words")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(window.routeTextCommand(event))
        XCTAssertEqual(pasteboard.string(forType: .string), "Selected words")
    }

    func testSameChatContentCanBeEmbeddedWithoutCreatingAnotherPresentation() throws {
        let controller = fixture()
        controller.presentFixture(question: "Earlier question", answer: .init(text: "Earlier answer", citations: []))
        let content = controller.takeContentForEmbedding()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView = content
        controller.prepareEmbedded(query: "Follow up here", contextMoment: Date(timeIntervalSince1970: 1_700_000_000))
        controller.setEmbeddedVisible(true)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.window === host)
        XCTAssertEqual(descendants(content).filter { $0 is LibreReverseAskAnswerView }.count, 1)
        let composer = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "ask.question" })
        XCTAssertEqual(composer.string, "Follow up here")
        XCTAssertTrue(composer.isEditable)
        controller.setEmbeddedVisible(false)
        XCTAssertEqual(composer.string, "Follow up here")
        XCTAssertEqual(descendants(content).filter { $0 is LibreReverseAskAnswerView }.count, 1)
    }

    func testCompletedChatSaveDrainsAtShutdownAndRestoresAllTwentyOneTurns() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: directory.appendingPathComponent("history.sqlite3"),
            keyFileURL: directory.appendingPathComponent("key"), mediaRoot: directory.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let store = LibreReverseAskChatStore(configuration: configuration)
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "Final saved answer", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in }, chatStore: store)
        for index in 0..<20 {
            controller.appendFixture(question: "Earlier question \(index)", answer: .init(text: "Earlier answer \(index)", citations: []))
        }
        let task = try XCTUnwrap(controller.requestAnswer(question: "Twenty-first question"))
        await task.value
        let owners = controller.beginShutdown()
        for owner in owners { await owner.value }
        let summaries = try await store.list()
        let id = try XCTUnwrap(summaries.first?.id)
        let saved = try await store.load(id: id)
        XCTAssertEqual(saved?.turns.count, 21)
        XCTAssertEqual(saved?.turns.first?.question, "Earlier question 0")
        // Distinct chats may have the same first question and display title.
        let secondID = UUID()
        try await store.save(id: secondID, turns: [.init(question: "Earlier question 0", answer: .init(text: "Other chat", citations: []))])
        let reopened = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in }, chatStore: store)
        reopened.loadChat(id: id)
        await reopened.fixtureWaitForHistory()
        let content = try XCTUnwrap(reopened.window?.contentView)
        XCTAssertEqual(descendants(content).filter { $0 is LibreReverseAskAnswerView }.count, 21)
        XCTAssertEqual(reopened.fixtureConversationCount, 6)
        let history = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "ask.saved-chats" })
        XCTAssertEqual(history.numberOfItems, 3)
        XCTAssertEqual(history.itemArray.dropFirst().compactMap { $0.representedObject as? UUID }.count, 2)
        for owner in reopened.beginShutdown() { await owner.value }
    }
    func testImmediateHistorySelectionAfterAnswerPreservesEveryCompletedTurn() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: directory.appendingPathComponent("history.sqlite3"),
            keyFileURL: directory.appendingPathComponent("key"), mediaRoot: directory.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let store = LibreReverseAskChatStore(configuration: configuration)
        let controller = LibreReverseAskWindowController(answerHandler: { question, _ in .init(text: "Answer to " + question, citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: {}, openMoment: { _ in }, chatStore: store)
        let id = controller.fixtureCurrentChatID
        for index in 1...6 {
            let task = try XCTUnwrap(controller.requestAnswer(question: "Question \(index)"))
            await task.value
            // Selection occurs immediately, without awaiting the admitted save.
            controller.loadChat(id: id)
            await controller.fixtureWaitForHistory()
            let saved = try await store.load(id: id)
            XCTAssertEqual(saved?.turns.count, index)
            XCTAssertEqual(saved?.turns.last?.question, "Question \(index)")
            let content = try XCTUnwrap(controller.window?.contentView)
            XCTAssertEqual(descendants(content).filter { $0 is LibreReverseAskAnswerView }.count, index)
        }
        for owner in controller.beginShutdown() { await owner.value }
    }

}
