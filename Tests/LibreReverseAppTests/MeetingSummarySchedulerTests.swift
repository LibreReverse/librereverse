import XCTest
@testable import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class MeetingSummarySchedulerTests: XCTestCase {
    private func job(_ id: Int64) -> LibreReverseMeetingSummaryJob {
        .init(eventID: id, segmentID: id, transcript: "fixture")
    }

    func testStartIsIdempotentAndStopAwaitsProviderBeforeRestart() async throws {
        let entered = expectation(description: "provider entered")
        let restarted = expectation(description: "success after restart")
        var providerContinuation: CheckedContinuation<Void, Never>?
        var providerCalls = 0
        var persisted = 0
        var stopped = 0
        let scheduler = MeetingSummaryScheduler(loadJobs: { [self.job(1)] }, summarize: { _ in
            providerCalls += 1
            if providerCalls == 1 {
                await withCheckedContinuation { continuation in
                    providerContinuation = continuation
                    entered.fulfill()
                }
            }
            return .init(text: "summary", isLocal: true)
        }, finish: { _, result in
            XCTAssertNotNil(result)
            persisted += 1
            restarted.fulfill()
        }, onStopped: { stopped += 1 })
        scheduler.start()
        scheduler.start()
        await fulfillment(of: [entered], timeout: 2)
        var stopFinished = false
        let stopping = Task {
            await scheduler.stop()
            stopFinished = true
        }
        await Task.yield()
        scheduler.start()
        XCTAssertFalse(stopFinished)
        XCTAssertEqual(providerCalls, 1)
        let continuation = try XCTUnwrap(providerContinuation)
        continuation.resume()
        await stopping.value
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(persisted, 0, "Cancellation must discard the old provider result without scheduling a failure")
        scheduler.start()
        await fulfillment(of: [restarted], timeout: 2)
        await scheduler.stop()
        XCTAssertEqual(stopped, 2)
        XCTAssertEqual(providerCalls, 2)
        XCTAssertEqual(persisted, 1)
    }

    func testFailedJobPersistsRetryWithoutPreventingFollowingSuccess() async {
        enum Failure: Error { case unavailable }
        let completed = expectation(description: "batch persisted")
        var retries: [Int64] = []
        var successes: [Int64] = []
        let scheduler = MeetingSummaryScheduler(loadJobs: { [self.job(1), self.job(2)] }, summarize: { job in
            if job.eventID == 1 { throw Failure.unavailable }
            return .init(text: "summary", isLocal: false)
        }, finish: { job, summary in
            if let summary {
                XCTAssertFalse(summary.isLocal)
                successes.append(job.eventID)
            } else {
                retries.append(job.eventID)
            }
        }, onBatchFinished: { result in
            XCTAssertEqual(result.completed, 1)
            XCTAssertEqual(result.failed, 1)
            completed.fulfill()
        })
        scheduler.start()
        await fulfillment(of: [completed], timeout: 2)
        await scheduler.stop()
        XCTAssertEqual(retries, [1])
        XCTAssertEqual(successes, [2])
    }
}
