import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AskCoveragePresentationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func find<T: NSView>(_ id: String, in controller: LibreReverseAskWindowController, as type: T.Type) throws -> T {
        let root = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(root).compactMap { $0 as? T }.first { $0.accessibilityIdentifier() == id })
    }
    private func controller() -> LibreReverseAskWindowController {
        _ = NSApplication.shared
        return LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "answer", citations: []) },
            loadAPIKey: { "synthetic-key" }, openAISettings: { }, openMoment: { _ in })
    }

    func testCoverageIsSeparateCollapsedScrollableAndResetsForEveryAnswer() throws {
        let controller = controller()
        var answer = LibreReverseAskAnswer(text: "The decision was to ship in October.", citations: [])
        answer.coverageNotes = (1...30).map { "Synthetic coverage detail \($0): one source remains unavailable." }
        controller.presentFixture(question: "Synthetic question", answer: answer)
        let text = try find("ask.answer", in: controller, as: NSTextView.self)
        let toggle = try find("ask.coverage.toggle", in: controller, as: NSButton.self)
        let scroll = try find("ask.coverage.details", in: controller, as: NSScrollView.self)
        let details = try find("ask.coverage.text", in: controller, as: NSTextView.self)
        XCTAssertEqual(text.string, answer.text)
        XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(scroll.isHiddenOrHasHiddenAncestor)
        toggle.performClick(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(scroll.isHiddenOrHasHiddenAncestor)
        XCTAssertLessThanOrEqual(scroll.frame.height, 91)
        XCTAssertGreaterThan(details.frame.height, scroll.contentSize.height)
        XCTAssertTrue(details.string.contains("detail 30"))
        XCTAssertTrue(details.isSelectable)
        XCTAssertFalse(details.isEditable)
        XCTAssertEqual(text.string, answer.text)
        controller.presentFixture(question: "Next", answer: answer)
        let nextScroll = try find("ask.coverage.details", in: controller, as: NSScrollView.self)
        XCTAssertTrue(nextScroll.isHiddenOrHasHiddenAncestor)
        try find("ask.coverage.toggle", in: controller, as: NSButton.self).performClick(nil)
        XCTAssertFalse(nextScroll.isHiddenOrHasHiddenAncestor)
        controller.presentFixture(question: "No caveats", answer: .init(text: "Plain answer", citations: []))
        XCTAssertTrue(try find("ask.coverage.toggle", in: controller, as: NSButton.self).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try find("ask.coverage.details", in: controller, as: NSScrollView.self).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(try find("ask.answer", in: controller, as: NSTextView.self).string, "Plain answer")
    }

    private actor ProgressGate {
        var callback: (@Sendable (String) -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        func answer(_ callback: @escaping @Sendable (String) -> Void, started: XCTestExpectation) async -> LibreReverseAskAnswer {
            self.callback = callback
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
            return .init(text: "Final synthetic answer", citations: [])
        }
        func emit(_ value: String) { callback?(value) }
        func finish() { continuation?.resume(); continuation = nil }
    }

    func testProgressIsVisibleDuringRequestAndLateEventsCannotOverwriteCompletedAnswer() async throws {
        _ = NSApplication.shared
        let gate = ProgressGate()
        let started = expectation(description: "handler admitted")
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in
            XCTFail("Progress handler should take precedence")
            return .init(text: "wrong handler", citations: [])
        }, loadAPIKey: { "synthetic-key" }, openAISettings: { }, openMoment: { _ in },
        progressAnswerHandler: { _, _, progress in await gate.answer(progress, started: started) })
        let task = try XCTUnwrap(controller.requestAnswer(question: "Synthetic question"))
        await fulfillment(of: [started], timeout: 2)
        let status = try find("ask.status", in: controller, as: NSTextField.self)
        let toggle = try find("ask.activity.toggle", in: controller, as: NSButton.self)
        let details = try find("ask.activity.text", in: controller, as: NSTextView.self)
        await gate.emit("Reading two matching meetings")
        for _ in 0..<1_000 where status.stringValue != "Reading two matching meetings" { await Task.yield() }
        XCTAssertEqual(status.stringValue, "Reading two matching meetings")
        XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor, "Activity must be available while the answer panel is hidden")
        toggle.performClick(nil)
        XCTAssertFalse(details.isHiddenOrHasHiddenAncestor)
        await gate.emit("Checking supporting passages")
        for _ in 0..<1_000 where !details.string.contains("Checking supporting passages") { await Task.yield() }
        XCTAssertTrue(details.string.contains("Reading two matching meetings"))
        XCTAssertTrue(details.string.contains("Checking supporting passages"))
        await gate.finish()
        await task.value
        XCTAssertFalse(controller.fixtureHasElapsedTimer)
        XCTAssertTrue(details.isHiddenOrHasHiddenAncestor, "Completed answers reset the disclosure")
        await gate.emit("Late obsolete progress")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(status.stringValue, "")
        XCTAssertFalse(details.string.contains("Late obsolete progress"))
        XCTAssertEqual(try find("ask.answer", in: controller, as: NSTextView.self).string, "Final synthetic answer")
    }

    func testElapsedTracksRequestAndPhaseWithoutStreamingLogSpamAndCancelInvalidatesOwner() async throws {
        _ = NSApplication.shared
        let gate = ProgressGate()
        let started = expectation(description: "elapsed handler admitted")
        var now: TimeInterval = 100
        let controller = LibreReverseAskWindowController(answerHandler: { _, _ in .init(text: "unused", citations: []) },
            loadAPIKey: { "synthetic-key" }, openAISettings: { }, openMoment: { _ in },
            progressAnswerHandler: { _, _, progress in await gate.answer(progress, started: started) },
            elapsedNow: { now })
        let task = try XCTUnwrap(controller.requestAnswer(question: "Synthetic elapsed question"))
        await fulfillment(of: [started], timeout: 2)
        let elapsed = try find("ask.elapsed", in: controller, as: NSTextField.self)
        let status = try find("ask.status", in: controller, as: NSTextField.self)
        let cancel = try find("ask.cancel", in: controller, as: NSButton.self)
        let activity = try find("ask.activity.text", in: controller, as: NSTextView.self)
        XCTAssertTrue(controller.fixtureHasElapsedTimer)
        XCTAssertFalse(cancel.isHiddenOrHasHiddenAncestor)
        now = 107
        controller.fixtureRefreshElapsed()
        XCTAssertEqual(elapsed.stringValue, "0:07 elapsed · 0:07 on this step")
        await gate.emit("Waiting for synthetic provider")
        for _ in 0..<1_000 where status.stringValue != "Waiting for synthetic provider" { await Task.yield() }
        now = 112
        controller.fixtureRefreshElapsed()
        XCTAssertEqual(elapsed.stringValue, "0:12 elapsed · 0:05 on this step")
        await gate.emit("progress.update: Received 250 characters")
        for _ in 0..<1_000 where status.stringValue != "Received 250 characters" { await Task.yield() }
        now = 115
        controller.fixtureRefreshElapsed()
        XCTAssertEqual(status.stringValue, "Received 250 characters")
        XCTAssertEqual(elapsed.stringValue, "0:15 elapsed · 0:08 on this step")
        XCTAssertEqual(activity.string, "Waiting for synthetic provider", "Ticks and streaming updates must not add log entries")
        cancel.performClick(nil)
        XCTAssertFalse(controller.fixtureHasElapsedTimer)
        XCTAssertTrue(cancel.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(elapsed.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(status.stringValue, "Request cancelled.")
        let composer = try find("ask.question", in: controller, as: NSTextView.self)
        XCTAssertTrue(composer.isEditable)
        XCTAssertEqual(composer.string, "Synthetic elapsed question")
        await gate.emit("progress.update: Obsolete content")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(status.stringValue, "Request cancelled.")
        let owners = controller.beginShutdown()
        XCTAssertEqual(owners.count, 1, "Cancelled work remains owned until its actual exit")
        await gate.finish()
        await task.value
        XCTAssertFalse(controller.fixtureHasElapsedTimer)
        XCTAssertEqual(status.stringValue, "Request cancelled.")
        XCTAssertTrue(controller.beginShutdown().isEmpty)
    }
}
