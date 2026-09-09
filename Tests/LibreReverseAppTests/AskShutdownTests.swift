#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

final class AskShutdownTests: XCTestCase {
    private actor BlockedAnswers {
        var continuations: [String: CheckedContinuation<Void, Never>] = [:]
        var count = 0

        func answer(_ question: String, started: XCTestExpectation) async -> LibreReverseAskAnswer {
            count += 1
            await withCheckedContinuation { continuation in
                continuations[question] = continuation
                started.fulfill()
            }
            // Deliberately ignore cancellation: shutdown must await actual exit.
            return .init(text: question, citations: [])
        }

        func release(_ question: String) { continuations.removeValue(forKey: question)?.resume() }
        func callCount() -> Int { count }
    }

    @MainActor
    func testShutdownDrainsClosedAndReplacedRequestsWithoutLosingSuccessor() async throws {
        _ = NSApplication.shared
        let firstStarted = expectation(description: "first request blocked")
        let secondStarted = expectation(description: "replacement request blocked")
        let answers = BlockedAnswers()
        let controller = LibreReverseAskWindowController(
            answerHandler: { question, _ in
                await answers.answer(question, started: question == "first" ? firstStarted : secondStarted)
            }, loadAPIKey: { "test-key" }, saveAPIKey: { _ in }, openMoment: { _ in })
        let first = try XCTUnwrap(controller.requestAnswer(question: "first"))
        await fulfillment(of: [firstStarted], timeout: 2)
        controller.close()
        controller.requestAnswer(question: "second")
        await fulfillment(of: [secondStarted], timeout: 2)
        // Closing did not discard the first request's owner. Both must drain.
        let owners = controller.beginShutdown()
        XCTAssertEqual(owners.count, 2)
        XCTAssertTrue(owners.allSatisfy(\.isCancelled))
        controller.requestAnswer(question: "third")
        await answers.release("first")
        // A predecessor completing must not remove its blocked successor.
        await first.value
        XCTAssertEqual(controller.beginShutdown().count, 1)
        await answers.release("second")
        for owner in owners { await owner.value }
        XCTAssertTrue(controller.beginShutdown().isEmpty)
        controller.requestAnswer(question: "fourth")
        let count = await answers.callCount()
        XCTAssertEqual(count, 2)
    }
}
#endif
