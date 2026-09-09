#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class QueueConcurrencyTests: XCTestCase {
    func testIndependentQueueValuesSerializeCompoundMutationsThroughSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let actualQueue = actual.appendingPathComponent("queue")
        let queueAlias = root.appendingPathComponent("queue-alias")
        try FileManager.default.createDirectory(at: actualQueue, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: queueAlias, withDestinationURL: actualQueue)
        let roots = [actualQueue, alias.appendingPathComponent("queue"), queueAlias]
        let counter = actual.appendingPathComponent("counter")
        try Data("0".utf8).write(to: counter)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            do {
                let queue = LibreReverseMeetingTranscriptionQueue(
                    root: roots[index % roots.count]
                )
                try queue.withExclusiveAccess {
                    let current = Int(try String(contentsOf: counter, encoding: .utf8))!
                    // Recursive public mutations must neither deadlock nor drop
                    // the outer process lock.
                    try queue.withExclusiveAccess {
                        try Data(String(current + 1).utf8).write(to: counter, options: .atomic)
                    }
                }
            } catch {
                XCTFail("Concurrent mutation failed: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "100")
    }

    func testThrowingNestedMutationReleasesGate() throws {
        enum Failure: Error { case expected }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = LibreReverseMeetingTranscriptionQueue(root: root.appendingPathComponent("queue"))
        XCTAssertThrowsError(try queue.withExclusiveAccess {
            try queue.withExclusiveAccess { throw Failure.expected }
        })
        XCTAssertEqual(try queue.withExclusiveAccess { 42 }, 42)
    }
}
#endif
