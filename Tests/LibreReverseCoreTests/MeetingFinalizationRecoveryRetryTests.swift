#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingFinalizationRecoveryRetryTests: XCTestCase {
    func testLateNativeFinalizationIsReprobedWithoutDiscardingStagedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("meeting.mp4")
        try Data("still-finalizing".utf8).write(to: media)
        var attempts = 0
        var waits: [TimeInterval] = []
        let result = try await MeetingFinalizationRecoveryRetry.run(operation: {
            attempts += 1
            let bytes = try Data(contentsOf: media)
            guard bytes == Data("finalized".utf8) else {
                throw LibreReverseMeetingCrashRecoveryError.unreadableMedia
            }
            return bytes
        }, wait: { delay in
            waits.append(delay)
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
            if waits.count == 2 { try Data("finalized".utf8).write(to: media) }
        })
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, [2, 4])
        XCTAssertEqual(result, Data("finalized".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    func testUnfinishedMediaExhaustsBoundedProbesAndPropagatesFailure() async {
        var attempts = 0
        var waits: [TimeInterval] = []
        do {
            let _: Int = try await MeetingFinalizationRecoveryRetry.run(operation: {
                attempts += 1
                throw LibreReverseMeetingCrashRecoveryError.missingVideoTrack
            }, wait: { waits.append($0) })
            XCTFail("An unreadable recording must not be treated as recovered")
        } catch {
            XCTAssertEqual(error as? LibreReverseMeetingCrashRecoveryError, .missingVideoTrack)
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(waits, [2, 4, 8, 16])
    }

    func testInvalidOwnershipAndDimensionsAreRejectedWithoutRetry() async {
        for error: Error in [LibreReverseMeetingCaptureJournalError.invalidPublicationXID("invalid"),
                             LibreReverseMeetingCrashRecoveryError.videoDimensionsMismatch(
                                expectedWidth: 100, expectedHeight: 100, actualWidth: 50, actualHeight: 50)] {
            var attempts = 0
            do {
                let _: Int = try await MeetingFinalizationRecoveryRetry.run(operation: {
                    attempts += 1
                    throw error
                }, wait: { _ in XCTFail("Structural rejection cannot become valid by waiting") })
                XCTFail("Invalid recovery succeeded")
            } catch {}
            XCTAssertEqual(attempts, 1)
        }
    }

    func testCancellationDuringDelayDoesNotStartAnotherProbe() async {
        var attempts = 0
        do {
            let _: Int = try await MeetingFinalizationRecoveryRetry.run(operation: {
                attempts += 1
                throw LibreReverseMeetingCrashRecoveryError.unreadableMedia
            }, wait: { _ in throw CancellationError() })
            XCTFail("Cancelled recovery succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }
}
#endif
