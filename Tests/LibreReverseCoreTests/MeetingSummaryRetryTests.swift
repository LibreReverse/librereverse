#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingSummaryRetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testRetrySurvivesReopeningAndBacksOffWithoutChangingLegacyVersion() throws {
        let library = try fixture(jobs: 1)
        defer { try? FileManager.default.removeItem(at: library.databaseURL.deletingLastPathComponent()) }
        // A legacy retry row with no product metadata is eligible immediately.
        try execute("UPDATE summary SET status='localRetrying'", library)
        XCTAssertEqual(try pending(library, at: now), [1])
        try fail(1, library, at: now)
        // Each call opens a fresh SQLCipher connection; state cannot reside in memory.
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(59)), [])
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(60)), [1])
        try fail(1, library, at: now.addingTimeInterval(60))
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(179)), [])
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(180)), [1])
        XCTAssertEqual(try scalar("SELECT attempts FROM librereverse_summary_retry", library), 2)
        XCTAssertEqual(try scalar("PRAGMA user_version", library), 41)
    }

    func testMoreThanEightFailuresDoNotStarveRemainingOrNewJobs() throws {
        let library = try fixture(jobs: 12)
        defer { try? FileManager.default.removeItem(at: library.databaseURL.deletingLastPathComponent()) }
        let first = try pending(library, at: now)
        XCTAssertEqual(first, Array(1...8).map(Int64.init))
        for id in first { try fail(id, library, at: now) }
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(15)), [9, 10, 11, 12])
        for id in 9...12 { try fail(Int64(id), library, at: now.addingTimeInterval(15)) }
        try addJob(13, library)
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(30)), [13])
        // Once all failures are due, their oldest retry deadlines win fairly.
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: 13, text: "done", configuration: library, now: now)
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(80)), first)
    }

    func testSuccessAndEventDeletionCleanUpRetryState() throws {
        let library = try fixture(jobs: 2)
        defer { try? FileManager.default.removeItem(at: library.databaseURL.deletingLastPathComponent()) }
        try fail(1, library, at: now)
        try fail(2, library, at: now)
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: 1, text: "summary", configuration: library, now: now)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM librereverse_summary_retry", library), 1)
        // A late failure must not turn a committed success back into a retry.
        try fail(1, library, at: now)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM librereverse_summary_retry WHERE eventID=1", library), 0)
        try execute("DELETE FROM event WHERE id=2", library)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM librereverse_summary_retry", library), 0)
        XCTAssertEqual(try pending(library, at: now.addingTimeInterval(5000)), [])
    }

    func testRepeatedProviderFailuresHaveCappedDelayAndRemainRetryable() throws {
        let library = try fixture(jobs: 1)
        defer { try? FileManager.default.removeItem(at: library.databaseURL.deletingLastPathComponent()) }
        var time = now
        for attempt in 1...12 {
            try fail(1, library, at: time)
            let delay = min(3600.0, 60 * pow(2, Double(attempt - 1)))
            XCTAssertEqual(try pending(library, at: time.addingTimeInterval(delay - 1)), [])
            time = time.addingTimeInterval(delay)
            XCTAssertEqual(try pending(library, at: time), [1])
        }
    }

    private func pending(_ library: LibreReverseLibraryConfiguration, at date: Date) throws -> [Int64] {
        try LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library, now: date).map(\.eventID)
    }

    private func fail(_ id: Int64, _ library: LibreReverseLibraryConfiguration, at date: Date) throws {
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: id, text: nil, configuration: library, now: date)
    }

    private func fixture(jobs: Int) throws -> LibreReverseLibraryConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(library)
        for id in 1...jobs { try addJob(Int64(id), library) }
        return library
    }

    private func addJob(_ id: Int64, _ library: LibreReverseLibraryConfiguration) throws {
        try execute("INSERT INTO event(id,type,status,segmentID) VALUES(\(id),'meeting','completed',\(id)); INSERT INTO summary(eventId,status) VALUES(\(id),'localQueued')", library)
    }

    private func database<T>(_ library: LibreReverseLibraryConfiguration, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.databaseURL.path, &raw), SQLITE_OK)
        let db = try XCTUnwrap(raw)
        defer { sqlite3_close(db) }
        let key = try Data(contentsOf: library.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(db, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil), SQLITE_OK)
        return try body(db)
    }

    private func execute(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws {
        try database(library) { db in
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws -> Int64 {
        try database(library) { db in
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &raw, nil), SQLITE_OK)
            let statement = try XCTUnwrap(raw)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
    }
}
#endif
