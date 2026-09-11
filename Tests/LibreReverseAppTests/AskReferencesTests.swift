#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AskReferencesTests: XCTestCase {
    func testExpandAllSourcesPreservesNumbersNavigationAndCopyThenCollapses() throws {
        _ = NSApplication.shared
        var opened: Date?
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: { }, openMoment: { opened = $0 })
        let citations = (0..<12).map { index in
            LibreReverseAskCitation(instant: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                title: "Synthetic source \(index + 1)", excerpt: "Synthetic evidence \(index + 1)", source: "Meeting")
        }
        let answer = LibreReverseAskAnswer(text: "Synthetic answer [12]", citations: citations)
        controller.presentFixture(question: "Synthetic question", answer: answer)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let toggle = try button("ask.sources.toggle", in: content)
        let sourceRows = descendants(content).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier().hasPrefix("ask.source.") == true }
        XCTAssertEqual(sourceRows.count, 12)
        XCTAssertEqual(sourceRows.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 3)
        XCTAssertEqual(toggle.title, "Show all 12 sources")
        XCTAssertEqual(controller.fixtureCitationCopyText, answer.textWithCitations)

        toggle.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(toggle.title, "Show fewer sources")
        XCTAssertEqual(sourceRows.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 12)
        let scroll = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "ask.sources.list" } as? NSScrollView)
        XCTAssertLessThanOrEqual(scroll.frame.height, 240.1)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        let last = try button("ask.source.12", in: content)
        XCTAssertTrue(last.accessibilityLabel()?.hasPrefix("Moment 12,") == true)
        last.scrollToVisible(last.bounds)
        last.performClick(nil)
        XCTAssertEqual(opened, citations[11].instant)
        XCTAssertEqual(controller.fixtureCitationCopyText, answer.textWithCitations,
            "Expansion must not change which references are copied")
        XCTAssertGreaterThan(last.frame.width, 100, "Rows must resize to the visible scroll width")

        toggle.performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(sourceRows.filter { !$0.isHiddenOrHasHiddenAncestor }.count, 3)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.1)
        XCTAssertEqual(controller.fixtureCitationCopyText, answer.textWithCitations)
    }

    func testNewAnswerResetsExpandedStateAndSmallListsNeedNoToggle() throws {
        _ = NSApplication.shared
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "", citations: []) },
            loadAPIKey: { "synthetic" }, openAISettings: { }, openMoment: { _ in })
        func answer(_ count: Int) -> LibreReverseAskAnswer {
            .init(text: "Synthetic", citations: (0..<count).map {
                .init(instant: Date(timeIntervalSince1970: Double($0)), title: "Synthetic \($0)", excerpt: "Synthetic", source: "Screen")
            })
        }
        controller.presentFixture(question: "First", answer: answer(6))
        let content = try XCTUnwrap(controller.window?.contentView)
        try button("ask.sources.toggle", in: content).performClick(nil)
        controller.presentFixture(question: "Second", answer: answer(5))
        XCTAssertEqual(try button("ask.sources.toggle", in: content).title, "Show all 5 sources")
        XCTAssertTrue(try button("ask.source.5", in: content).isHiddenOrHasHiddenAncestor)
        controller.presentFixture(question: "Third", answer: answer(2))
        XCTAssertTrue(try button("ask.sources.toggle", in: content).isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(try button("ask.source.2", in: content).isHiddenOrHasHiddenAncestor)
        controller.presentFixture(question: "Empty", answer: answer(0))
        let scroll = try XCTUnwrap(descendants(content).first { $0.accessibilityIdentifier() == "ask.sources.list" })
        XCTAssertTrue(scroll.isHiddenOrHasHiddenAncestor)
    }

    private func button(_ identifier: String, in root: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == identifier } as? NSButton)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }
}
#endif
