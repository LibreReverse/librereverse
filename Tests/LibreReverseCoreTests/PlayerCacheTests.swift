import XCTest

@testable import LibreReverseCore

/// Covers the player cache LRU bound.
final class PlayerCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func access(
        _ entries: [PlayerCache.Entry<String>],
        _ key: String,
        _ offset: TimeInterval
    ) -> PlayerCache.Outcome<String> {
        PlayerCache.access(entries, key: key, at: date(offset))
    }

    func testRecoveredCapacity() {
        XCTAssertEqual(PlayerCache.capacity, 5)
    }

    func testFillingToCapacityEvictsNothing() {
        var entries: [PlayerCache.Entry<String>] = []
        for index in 0..<5 {
            let outcome = access(entries, "chunk-\(index)", TimeInterval(index))
            XCTAssertTrue(outcome.created)
            XCTAssertTrue(outcome.evicted.isEmpty)
            entries = outcome.entries
        }
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.map(\.key), (0..<5).map { "chunk-\($0)" })
    }

    func testSixthDistinctKeyEvictsExactlyTheLeastRecentlyUsed() {
        var entries: [PlayerCache.Entry<String>] = []
        for index in 0..<5 {
            entries = access(entries, "chunk-\(index)", TimeInterval(index)).entries
        }
        let outcome = access(entries, "chunk-5", 5)
        XCTAssertEqual(outcome.evicted, ["chunk-0"])
        XCTAssertEqual(outcome.entries.count, 5)
        XCTAssertEqual(
            outcome.entries.map(\.key),
            ["chunk-1", "chunk-2", "chunk-3", "chunk-4", "chunk-5"]
        )
    }

    func testTouchingARetainedKeyReusesItAndRestampsRecency() {
        var entries: [PlayerCache.Entry<String>] = []
        for index in 0..<5 {
            entries = access(entries, "chunk-\(index)", TimeInterval(index)).entries
        }
        let reuse = access(entries, "chunk-0", 10)
        XCTAssertFalse(reuse.created)
        XCTAssertTrue(reuse.evicted.isEmpty)
        XCTAssertEqual(reuse.entries.count, 5)
        // chunk-0 is now the most recent, so chunk-1 becomes the eviction head.
        XCTAssertEqual(reuse.entries.last?.key, "chunk-0")
        XCTAssertEqual(reuse.entries.first?.key, "chunk-1")

        let next = access(reuse.entries, "chunk-9", 11)
        XCTAssertEqual(next.evicted, ["chunk-1"])
    }

    /// The behavior that motivated the change: scrubbing back and forth across a
    /// chunk boundary must not rebuild either player.
    func testAlternatingAcrossABoundaryNeverRecreates() {
        var entries: [PlayerCache.Entry<String>] = []
        entries = access(entries, "left", 0).entries
        entries = access(entries, "right", 1).entries
        for step in 0..<20 {
            let key = step.isMultiple(of: 2) ? "left" : "right"
            let outcome = access(entries, key, TimeInterval(2 + step))
            XCTAssertFalse(outcome.created, "rebuilt \(key) at step \(step)")
            XCTAssertTrue(outcome.evicted.isEmpty)
            entries = outcome.entries
        }
        XCTAssertEqual(entries.count, 2)
    }

    func testFailedItemRemovalPreservesOtherRecencyAndForcesFreshAccess() {
        var entries: [PlayerCache.Entry<String>] = []
        entries = access(entries, "oldest", 0).entries
        entries = access(entries, "failed", 1).entries
        entries = access(entries, "newest", 2).entries

        entries = PlayerCache.removing("failed", from: entries)
        XCTAssertEqual(entries.map(\.key), ["oldest", "newest"])

        let retry = access(entries, "failed", 3)
        XCTAssertTrue(retry.created)
        XCTAssertTrue(retry.evicted.isEmpty)
        XCTAssertEqual(retry.entries.map(\.key), ["oldest", "newest", "failed"])
    }

}
