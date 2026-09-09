#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseShardStoreTests: XCTestCase {
    func testThirtyDayIntervalsAreHalfOpenUTCAndStableAcrossDST() throws {
        let epoch = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2025-02-19T00:00:00Z"
        ))
        let first = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        XCTAssertEqual(first.fileName, "20250219-20250321.sqlite3")
        XCTAssertTrue(first.contains(epoch))
        XCTAssertTrue(first.contains(first.end.addingTimeInterval(-0.001)))
        XCTAssertFalse(first.contains(first.end))
        XCTAssertEqual(
            LibreReverseShardInterval.ordinal(containing: first.end, epochStart: epoch),
            1
        )
        XCTAssertEqual(
            LibreReverseShardInterval.ordinal(
                containing: epoch.addingTimeInterval(-0.001),
                epochStart: epoch
            ),
            -1
        )
        XCTAssertEqual(first.end.timeIntervalSince(first.start), 30 * 86_400)
    }

    func testCatalogInitializationPersistsEpochAndStrictLifecycle() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = try LibreReverseShardStore.epochStart(configuration: configuration)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(epoch, utc.startOfDay(for: Date()))
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let id = try LibreReverseShardStore.registerBuildingShard(
            interval: interval,
            relativePath: "Shards/\(interval.fileName)",
            configuration: configuration
        )
        try LibreReverseShardStore.markSealedLocal(
            shardID: id,
            byteCount: 123,
            sha256: "abc",
            frameCount: 4,
            nodeCount: 5,
            documentCount: 6,
            minFrameID: 10,
            maxFrameID: 20,
            configuration: configuration
        )
        let record = try XCTUnwrap(LibreReverseShardStore.records(
            configuration: configuration
        ).first)
        XCTAssertEqual(record.state, .sealedLocal)
        XCTAssertEqual(record.interval, interval)
        XCTAssertEqual(record.relativePath, "Shards/\(interval.fileName)")
        XCTAssertEqual(record.byteCount, 123)
        XCTAssertEqual(record.frameCount, 4)
        XCTAssertThrowsError(try LibreReverseShardStore.markSealedLocal(
            shardID: id,
            byteCount: 123,
            sha256: "abc",
            frameCount: 4,
            nodeCount: 5,
            documentCount: 6,
            minFrameID: 10,
            maxFrameID: 20,
            configuration: configuration
        ))
    }

    func testCatalogEpochUsesEarliestFrameUTCDateAndSurvivesReinitialize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-epoch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        _ = try LibreReverseLibraryStore.admitFrame(
            createdAt: try XCTUnwrap(ISO8601DateFormatter().date(
                from: "2025-03-09T06:59:59Z"
            )),
            imageFileName: "first.png",
            context: nil,
            configuration: configuration
        )
        // The epoch is immutable after first initialization. A new empty
        // library starts at today's UTC day rather than being silently rebased
        // when its first frame arrives.
        let original = try LibreReverseShardStore.epochStart(configuration: configuration)
        try LibreReverseLibraryStore.initialize(configuration)
        XCTAssertEqual(
            try LibreReverseShardStore.epochStart(configuration: configuration),
            original
        )
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-store-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }
}
#endif
