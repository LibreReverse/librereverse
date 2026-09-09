import XCTest

@testable import LibreReverseCore

final class MeetingLibraryMutationScopeTests: XCTestCase {
    private enum FixtureError: Error, Equatable {
        case rejected
    }

    func testSuccessfulMutationBalancesPrimaryReplacementBarrierInOrder() async throws {
        let events = EventLog()

        let value = await LibreReverseMeetingLibraryMutationScope.perform {
            await events.append("prepare")
        } complete: {
            await events.append("complete")
        } operation: {
            await events.append("operation")
            return 42
        }

        XCTAssertEqual(value, 42)
        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["prepare", "operation", "complete"])
    }

    func testCancellationErrorStillCompletesPrimaryReplacementBarrier() async {
        let events = EventLog()

        do {
            _ = try await LibreReverseMeetingLibraryMutationScope.perform {
                await events.append("prepare")
            } complete: {
                await events.append("complete")
            } operation: {
                await events.append("operation")
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["prepare", "operation", "complete"])
    }

    func testMaintenanceSuccessorAloneOwnsCompletionAndRetry() {
        var state = LibreReverseMeetingMaintenanceTaskState()
        let predecessor = state.beginTask()
        let successor = state.beginTask()

        XCTAssertFalse(state.owns(predecessor))
        XCTAssertTrue(state.owns(successor))

        state.invalidate()
        XCTAssertFalse(state.owns(successor))
    }

    func testThrowingMutationStillCompletesPrimaryReplacementBarrier() async {
        let events = EventLog()

        do {
            _ = try await LibreReverseMeetingLibraryMutationScope.perform {
                await events.append("prepare")
            } complete: {
                await events.append("complete")
            } operation: {
                await events.append("operation")
                throw FixtureError.rejected
            }
            XCTFail("expected mutation failure")
        } catch {
            XCTAssertEqual(error as? FixtureError, .rejected)
        }

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["prepare", "operation", "complete"])
    }
}

private actor EventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
