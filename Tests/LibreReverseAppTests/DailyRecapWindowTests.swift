#if os(macOS)
import AppKit
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

@MainActor
final class DailyRecapWindowTests: XCTestCase {
    func testShutdownDrainsCanceledRecapReadsAndClosesAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = LibraryDatabaseSession(configuration: .init(
            databaseURL: root.appendingPathComponent("unused.sqlite3"),
            keyFileURL: root.appendingPathComponent("unused.key"), mediaRoot: root))
        let firstStarted = expectation(description: "first read blocked")
        let secondStarted = expectation(description: "replacement read blocked")
        var continuations: [CheckedContinuation<Void, Never>] = []
        var calls = 0
        let model = LibreReverseDailyRecapViewModel(session: session, evidenceLoader: { _ in
            calls += 1
            let started = calls == 1 ? firstStarted : secondStarted
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                started.fulfill()
            }
            return ([], [])
        })
        let first = try XCTUnwrap(model.reload())
        await fulfillment(of: [firstStarted], timeout: 2)
        model.cancel()
        let second = try XCTUnwrap(model.reload())
        await fulfillment(of: [secondStarted], timeout: 2)
        let owners = model.beginShutdown()
        XCTAssertEqual(owners.count, 3, "Two query owners plus the connection-close barrier")
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        XCTAssertNil(model.reload())
        continuations[0].resume()
        await first.value
        XCTAssertNil(model.recap, "Canceled predecessor cannot publish results")
        continuations[1].resume()
        for owner in owners { await owner.value }
        XCTAssertNil(model.reload())
        XCTAssertEqual(calls, 2)
        let connected = await session.hasConnection
        XCTAssertFalse(connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReadingWindowRetainsOpeningSizeAndFitsAvailableDisplay() throws {
        let controller = LibreReverseDailyRecapWindowController(
            fixtureRecap: LibreReverseDailyRecapFixture.make()
        )
        let window = try XCTUnwrap(controller.window)
        let contentSize = try XCTUnwrap(window.contentView?.bounds.size)

        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        XCTAssertEqual(contentSize.width, min(520, max(360, available.width - 40)), accuracy: 0.5)
        XCTAssertEqual(contentSize.height, min(800, max(560, available.height - 64)), accuracy: 0.5)
        XCTAssertEqual(window.minSize.width, 360, accuracy: 0.5)
        XCTAssertEqual(window.minSize.height, 560, accuracy: 0.5)
        controller.present()
        defer { window.close() }
        if let visible = window.screen?.visibleFrame {
            XCTAssertTrue(visible.contains(window.frame))
        }
    }
}
#endif
