import Foundation
import XCTest
@testable import LibreReverseApp

@MainActor
final class ShutdownBoundaryTests: XCTestCase {
    func testQuitRetainsInstallationLockUntilCancelledWriterAndCaptureFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var installation: LibreReverseInstallationLock? = try .init(directory: root)
        let writerStarted = expectation(description: "writer started")
        let stopStarted = expectation(description: "stop consumers")
        let captureStarted = expectation(description: "finish capture")
        var resumeWriter: CheckedContinuation<Void, Never>?
        var resumeCapture: CheckedContinuation<Void, Never>?
        var replied = false
        let writer = Task {
            await withCheckedContinuation { continuation in
                resumeWriter = continuation
                writerStarted.fulfill()
            }
            XCTAssertTrue(Task.isCancelled)
            // Cancellation cannot discard an in-flight persistence acknowledgement.
            try? Data("finished".utf8).write(to: root.appendingPathComponent("journal"))
        }
        await fulfillment(of: [writerStarted], timeout: 1)
        let shutdown = Task {
            await LibreReverseShutdownBoundary.complete(backgroundTasks: [writer],
                stopBackground: { stopStarted.fulfill() },
                finishCapture: {
                    await withCheckedContinuation { continuation in
                        resumeCapture = continuation
                        captureStarted.fulfill()
                    }
                }, reply: {
                    installation = nil
                    replied = true
                })
        }
        await fulfillment(of: [stopStarted], timeout: 1)
        XCTAssertFalse(replied)
        XCTAssertNotNil(installation)
        XCTAssertThrowsError(try LibreReverseInstallationLock(directory: root))
        resumeWriter?.resume()
        await fulfillment(of: [captureStarted], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal").path))
        XCTAssertFalse(replied)
        XCTAssertThrowsError(try LibreReverseInstallationLock(directory: root))
        resumeCapture?.resume()
        await shutdown.value
        XCTAssertTrue(replied)
        let successor = try LibreReverseInstallationLock(directory: root)
        withExtendedLifetime(successor) {}
    }
}
