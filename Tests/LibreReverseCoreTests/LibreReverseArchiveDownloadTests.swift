#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseArchiveDownloadTests: XCTestCase {
    private actor Worker: LibreReverseArchiveDownloading {
        var attempts = 0
        var failures: Int
        let connectionError: Bool
        let suspend: Bool
        init(failures: Int = 0, connectionError: Bool = false, suspend: Bool = false) {
            self.failures = failures; self.connectionError = connectionError; self.suspend = suspend
        }
        func count() -> Int { attempts }
        func download(_ request: LibreReverseDownloadRequest,
                      progress: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void) async throws {
            attempts += 1
            await progress(.init(request: request, phase: .history, transferID: "test"))
            if suspend { try await Task.sleep(nanoseconds: 30_000_000_000) }
            if failures > 0 {
                failures -= 1
                if connectionError { throw GoogleDriveConnectionError.notAuthorized }
                throw URLError(.networkConnectionLost)
            }
        }
    }

    private func fixture() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/key"), mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(library)
        return (root, library)
    }

    private func waitFor(_ phase: LibreReverseDownloadPhase, coordinator: LibreReverseArchiveDownloadCoordinator,
                         date: Date, timeout: TimeInterval = 10) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await coordinator.status(at: date)?.phase == phase { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Did not reach \(phase)")
    }

    func testTransientFailureRetriesWithoutAViewOrAnotherClick() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Worker(failures: 1)
        let queue = LibreReverseArchiveDownloadCoordinator(library: library, retrySeconds: 0.01)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await queue.connect(worker)
        try await queue.enqueue(date: date, shardOrdinal: 9)
        try await waitFor(.complete, coordinator: queue, date: date)
        let attempts = await worker.count()
        XCTAssertEqual(attempts, 2)
        let persisted = try LibreReverseDownloadRequestStore(library: library).load()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertNotNil(persisted.first?.completedAt)
        XCTAssertTrue(try LibreReverseDownloadRequestStore(library: library).protects(shardOrdinal: 9))
        await queue.pause(needsConnection: false)
    }

    func testRestartResumesSavedIntentWithoutReopeningTimeline() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = LibreReverseArchiveDownloadCoordinator(library: library)
        let suspended = Worker(suspend: true)
        try await first.connect(suspended)
        try await first.enqueue(date: date)
        try await waitFor(.history, coordinator: first, date: date)
        try await first.enqueue(date: date.addingTimeInterval(1))
        XCTAssertEqual(try LibreReverseDownloadRequestStore(library: library).load().count, 1)
        await first.pause(needsConnection: false)
        let restarted = LibreReverseArchiveDownloadCoordinator(library: library)
        let worker = Worker()
        try await restarted.connect(worker)
        try await waitFor(.complete, coordinator: restarted, date: date)
        let count = await worker.count()
        XCTAssertEqual(count, 1)
        await restarted.pause(needsConnection: false)
    }

    func testConnectionFailureParksIntentAndReconnectResumesIt() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = Worker(failures: 1, connectionError: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let queue = LibreReverseArchiveDownloadCoordinator(library: library, retrySeconds: 0.01)
        try await queue.connect(worker)
        try await queue.enqueue(date: date)
        try await waitFor(.disconnected, coordinator: queue, date: date)
        try await Task.sleep(nanoseconds: 100_000_000)
        let pausedCount = await worker.count()
        XCTAssertEqual(pausedCount, 1)
        try await queue.connect(worker)
        try await waitFor(.complete, coordinator: queue, date: date)
        let resumedCount = await worker.count()
        XCTAssertEqual(resumedCount, 2)
        await queue.pause(needsConnection: false)
    }

    func testEnqueueWhileDisconnectedSurvivesRelaunch() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let queue = LibreReverseArchiveDownloadCoordinator(library: library)
        await queue.pause(needsConnection: true)
        try await queue.enqueue(date: date)
        let status = try await queue.status(at: date)
        XCTAssertEqual(status?.phase, .disconnected)
        let restarted = LibreReverseArchiveDownloadCoordinator(library: library)
        try await restarted.connect(Worker())
        try await waitFor(.complete, coordinator: restarted, date: date)
        await restarted.pause(needsConnection: false)
    }
}
#endif
