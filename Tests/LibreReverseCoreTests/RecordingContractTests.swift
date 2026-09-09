import XCTest
@testable import LibreReverseCore

final class RecordingContractTests: XCTestCase {
    func testAdmissionThreshold() {
        XCTAssertFalse(CaptureAdmissionPolicy.admits(changedPixels: 999))
        XCTAssertTrue(CaptureAdmissionPolicy.admits(changedPixels: 1_000))
    }

    func testBitrateScalesWithDimensionsAndRejectsUnsupportedInputs() {
        XCTAssertEqual(WriterContract.averageBitRate(width: 3024, height: 1964, frameRate: 30), 11_358_597)
        XCTAssertNil(WriterContract.averageBitRate(width: 3024, height: 1964, frameRate: 15))
        XCTAssertNil(WriterContract.averageBitRate(width: -1, height: 1964, frameRate: 30))
        XCTAssertNil(WriterContract.averageBitRate(width: Int.max, height: Int.max, frameRate: 30))
    }

    func testStalledScreenshotRejectsEveryTickUntilCompletionThenAllowsNextCapture() async {
        let gate = ScreenshotCaptureGate()
        let first = await gate.beginScreenshot()
        XCTAssertEqual(first, .admitted)

        // Simulate a capture which never completes while another 1,000 timer
        // ticks arrive. Dropping work must never increase admission capacity.
        for _ in 0..<1_000 {
            let decision = await gate.beginScreenshot()
            XCTAssertEqual(decision, .dropped)
        }
        await gate.finishScreenshot()
        let next = await gate.beginScreenshot()
        XCTAssertEqual(next, .admitted)
        let overlapping = await gate.beginScreenshot()
        XCTAssertEqual(overlapping, .dropped)
        await gate.finishScreenshot()
    }

    func testConcurrentCaptureRequestsHaveExactlyOneOwner() async {
        let gate = ScreenshotCaptureGate()
        let admittedCount = await withTaskGroup(of: ScreenshotAdmissionDecision.self) { group in
            for _ in 0..<100 {
                group.addTask { await gate.beginScreenshot() }
            }
            var admitted = 0
            for await decision in group where decision == .admitted { admitted += 1 }
            return admitted
        }
        XCTAssertEqual(admittedCount, 1)
        await gate.finishScreenshot()
        let next = await gate.beginScreenshot()
        XCTAssertEqual(next, .admitted)
        await gate.finishScreenshot()
    }

    func testShutdownWaitsForInFlightScreenshotAndPermanentlyRejectsNewTicks() async {
        let gate = ScreenshotCaptureGate()
        let first = await gate.beginScreenshot()
        XCTAssertEqual(first, .admitted)
        let earlyDrain = expectation(description: "must not drain before screenshot finishes")
        earlyDrain.isInverted = true
        let shutdown = Task {
            await gate.stopAndDrain()
            earlyDrain.fulfill()
        }
        // A cancelled shutdown still must await admitted durable work.
        shutdown.cancel()
        await fulfillment(of: [earlyDrain], timeout: 0.05)
        await gate.finishScreenshot()
        await shutdown.value
        let later = await gate.beginScreenshot()
        XCTAssertEqual(later, .dropped)
        // Reset followed by application termination must be harmless.
        await gate.stopAndDrain()
    }

    func testIdleShutdownImmediatelyAndPermanentlyClosesAdmission() async {
        let gate = ScreenshotCaptureGate()
        await gate.stopAndDrain()
        await gate.stopAndDrain()
        let decision = await gate.beginScreenshot()
        XCTAssertEqual(decision, .dropped)
    }

}
