import XCTest
import AVFoundation
@testable import LibreReverseApp

private final class ReadinessSource: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (AVPlayerItem.Status) -> Void)?
    private var cleanupCount = 0
    var removals: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanupCount
    }

    func observe(initial: AVPlayerItem.Status,
                 receive: @escaping @Sendable (AVPlayerItem.Status) -> Void) -> (() -> Void) {
        lock.lock()
        callback = receive
        lock.unlock()
        receive(initial)
        return { [self] in
            lock.lock()
            cleanupCount += 1
            callback = nil
            lock.unlock()
        }
    }

    func send(_ status: AVPlayerItem.Status) {
        lock.lock()
        let receive = callback
        lock.unlock()
        receive?(status)
    }
}

@MainActor
final class PlayerCacheLifecycleTests: XCTestCase {
    func testInitialTerminalStatusAndSynchronousRegistrationTransition() async {
        for status in [AVPlayerItem.Status.readyToPlay, .failed] {
            let source = ReadinessSource()
            let ready = await LibreReverseItemReadiness.wait { receive in
                source.observe(initial: status, receive: receive)
            }
            XCTAssertEqual(ready, status == .readyToPlay)
            XCTAssertEqual(source.removals, 1)
        }
        let source = ReadinessSource()
        let ready = await LibreReverseItemReadiness.wait { receive in
            let cleanup = source.observe(initial: .unknown, receive: receive)
            // Completion before the observer registration returns used to be lost.
            source.send(.readyToPlay)
            source.send(.failed)
            return cleanup
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(source.removals, 1)
    }

    func testUnknownStatusTimesOutAndRemovesObservation() async {
        let source = ReadinessSource()
        let ready = await LibreReverseItemReadiness.wait(timeout: .milliseconds(20)) { receive in
            source.observe(initial: .unknown, receive: receive)
        }
        XCTAssertFalse(ready)
        XCTAssertEqual(source.removals, 1)
    }

    func testCancellationRemovesObservationWithoutWaitingForDeadline() async {
        let source = ReadinessSource()
        let registered = expectation(description: "Observer registered")
        let task = Task { @MainActor in
            await LibreReverseItemReadiness.wait(timeout: .seconds(60)) { receive in
                let cleanup = source.observe(initial: .unknown, receive: receive)
                registered.fulfill()
                return cleanup
            }
        }
        await fulfillment(of: [registered], timeout: 1)
        task.cancel()
        let ready = await task.value
        XCTAssertFalse(ready)
        XCTAssertEqual(source.removals, 1)
    }

    func testRepeatedChunkSwitchesRetainOneOutputPerItem() async throws {
        let cache = LibreReversePlayerCache(readiness: { _ in true })
        let urls = [URL(fileURLWithPath: "/nonexistent/cache-a.mp4"),
                    URL(fileURLWithPath: "/nonexistent/cache-b.mp4")]
        let players = urls.map { cache.player(for: $0).player }
        for iteration in 0..<200 {
            let selected = await cache.setCurrentPlayer(for: urls[iteration % 2])
            let selection = try XCTUnwrap(selected)
            XCTAssertEqual(selection.item.outputs.count, 1)
            XCTAssertTrue(selection.requiresLayerTransition)
        }
        XCTAssertEqual(cache.retainedCount, 2)
        for player in players { XCTAssertEqual(player.currentItem?.outputs.count, 1) }
        var evicted: [URL] = []
        cache.onEvict = { evicted.append($0) }
        cache.removeAll()
        XCTAssertEqual(Set(evicted), Set(urls))
        XCTAssertEqual(cache.retainedCount, 0)
    }

    func testOlderReadinessCompletionCannotReplaceNewerSelection() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        var callCount = 0
        let registered = expectation(description: "First selection suspended")
        let cache = LibreReversePlayerCache(readiness: { _ in
            callCount += 1
            if callCount != 1 { return true }
            return await withCheckedContinuation { continuation in
                pending = continuation
                registered.fulfill()
            }
        })
        let first = URL(fileURLWithPath: "/nonexistent/older.mp4")
        let second = URL(fileURLWithPath: "/nonexistent/newer.mp4")
        _ = cache.player(for: first)
        _ = cache.player(for: second)
        let oldSelection = Task { await cache.setCurrentPlayer(for: first) }
        await fulfillment(of: [registered], timeout: 1)
        let newSelection = await cache.setCurrentPlayer(for: second)
        XCTAssertNotNil(newSelection)
        pending?.resume(returning: true)
        let stale = await oldSelection.value
        XCTAssertNil(stale)
        let repeated = await cache.setCurrentPlayer(for: second)
        XCTAssertEqual(repeated?.requiresLayerTransition, false)
        cache.removeAll()
    }

    func testRecycledPlayerCannotPublishOriginalItemAfterReadinessCompletes() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        let registered = expectation(description: "Readiness suspended")
        let cache = LibreReversePlayerCache(readiness: { _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                registered.fulfill()
            }
        })
        let originalURL = URL(fileURLWithPath: "/nonexistent/cache-original.mp4")
        let player = cache.player(for: originalURL, now: Date(timeIntervalSince1970: 0)).player
        let originalItem = player.currentItem
        let task = Task { await cache.setCurrentPlayer(for: originalURL) }
        await fulfillment(of: [registered], timeout: 1)
        for index in 1...5 {
            _ = cache.player(for: URL(fileURLWithPath: "/nonexistent/cache-\(index).mp4"),
                             now: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertFalse(player.currentItem === originalItem)
        pending?.resume(returning: true)
        let selection = await task.value
        XCTAssertNil(selection)
        cache.removeAll()
    }
}
