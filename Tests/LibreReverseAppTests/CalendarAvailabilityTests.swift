#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseApp

@MainActor
final class CalendarAvailabilityTests: XCTestCase {
    func testInvalidationRejectsSuspendedResultAndAllowsFreshLoad() async throws {
        let loader = CalendarAvailabilitySuspendedLoader()
        let cache = LibreReverseCalendarAvailability { try await loader.load($0) }
        let key = periods(0)
        let old = Task { try await cache.load(key) }
        await loader.waitForRequests(1)
        cache.invalidate()
        let fresh = Task { try await cache.load(key) }
        await loader.waitForRequests(2)
        let freshDate = Date(timeIntervalSince1970: 2)
        await loader.complete(1, with: [freshDate])
        let freshResult = try await fresh.value
        XCTAssertEqual(freshResult, [freshDate])
        await loader.complete(0, with: [Date(timeIntervalSince1970: 1)])
        do { _ = try await old.value; XCTFail("Invalidated read published") }
        catch is CancellationError {}
        XCTAssertEqual(cache.cached(key), [freshDate])
    }

    func testCancellingOneIndependentReadDoesNotCancelOrCacheOverItsSibling() async throws {
        let loader = CalendarAvailabilitySuspendedLoader()
        let cache = LibreReverseCalendarAvailability { try await loader.load($0) }
        let key = periods(0)
        let cancelled = Task { try await cache.load(key) }
        await loader.waitForRequests(1)
        let survivor = Task { try await cache.load(key) }
        await loader.waitForRequests(2)
        cancelled.cancel()
        await loader.complete(1, with: [])
        let survivingResult = try await survivor.value
        XCTAssertEqual(survivingResult, [])
        await loader.complete(0, with: [Date(timeIntervalSince1970: 1)])
        do { _ = try await cancelled.value; XCTFail("Cancelled read succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(cache.cached(key), [], "Empty availability is a cached result")
    }

    func testCacheRetainsExactly32EntriesAndReadPromotesRecency() async throws {
        let cache = LibreReverseCalendarAvailability { $0.map(\.start) }
        for index in 0..<32 { _ = try await cache.load(periods(index)) }
        XCTAssertNotNil(cache.cached(periods(0)))
        _ = try await cache.load(periods(32))
        XCTAssertNil(cache.cached(periods(1)), "Least recently used entry must be evicted")
        XCTAssertNotNil(cache.cached(periods(0)))
        XCTAssertEqual((0...32).filter { cache.cached(periods($0)) != nil }.count, 32)
        cache.invalidate()
        XCTAssertTrue((0...32).allSatisfy { cache.cached(periods($0)) == nil })
    }

    func testEmptyResultAvoidsSecondReadAndPeriodBoundariesRemainDistinct() async throws {
        let loader = CalendarAvailabilityCountingLoader()
        let cache = LibreReverseCalendarAvailability { await loader.load($0) }
        let key = periods(0)
        _ = try await cache.load(key)
        _ = try await cache.load(key)
        XCTAssertEqual(cache.cached(key), [])
        let count = await loader.count
        XCTAssertEqual(count, 1)
        let differentEnd = [DateInterval(start: key[0].start, duration: 2)]
        XCTAssertNil(cache.cached(differentEnd))
        _ = try await cache.load(differentEnd)
        let finalCount = await loader.count
        XCTAssertEqual(finalCount, 2)
    }

    func testRefreshRevalidatesCachedEmptyPeriodAfterNewRecording() async throws {
        let loader = CalendarAvailabilitySuspendedLoader()
        let cache = LibreReverseCalendarAvailability { try await loader.load($0) }
        let key = periods(0)
        let initial = Task { try await cache.load(key) }
        await loader.waitForRequests(1)
        await loader.complete(0, with: [])
        _ = try await initial.value
        XCTAssertEqual(cache.cached(key), [])

        let refresh = Task { try await cache.refresh(key) }
        await loader.waitForRequests(2)
        XCTAssertEqual(cache.cached(key), [], "Cached UI remains available during refresh")
        let recorded = key[0].start
        await loader.complete(1, with: [recorded])
        let refreshed = try await refresh.value
        XCTAssertEqual(refreshed, [recorded])
        XCTAssertEqual(cache.cached(key), [recorded])
        let loaded = try await cache.load(key)
        XCTAssertEqual(loaded, [recorded])
    }

    func testNewerRefreshWinsOverOlderWarmLoadForSamePeriod() async throws {
        let loader = CalendarAvailabilitySuspendedLoader()
        let cache = LibreReverseCalendarAvailability { try await loader.load($0) }
        let key = periods(0)
        let warm = Task { try await cache.load(key) }
        await loader.waitForRequests(1)
        let refresh = Task { try await cache.refresh(key) }
        await loader.waitForRequests(2)
        let recorded = key[0].start
        await loader.complete(1, with: [recorded])
        _ = try await refresh.value
        await loader.complete(0, with: [])
        do { _ = try await warm.value; XCTFail("Old warm load replaced fresh availability") }
        catch is CancellationError {}
        XCTAssertEqual(cache.cached(key), [recorded])
    }

    private func periods(_ index: Int) -> [DateInterval] {
        [DateInterval(start: Date(timeIntervalSince1970: Double(index) * 10), duration: 1)]
    }
}

private actor CalendarAvailabilityCountingLoader {
    private(set) var count = 0
    func load(_ periods: [DateInterval]) -> [Date] { count += 1; return [] }
}

private actor CalendarAvailabilitySuspendedLoader {
    private var continuations: [CheckedContinuation<[Date], Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ periods: [DateInterval]) async throws -> [Date] {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            let ready = waiters.filter { continuations.count >= $0.0 }
            waiters.removeAll { continuations.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with value: [Date]) {
        continuations[index].resume(returning: value)
    }
}
#endif
