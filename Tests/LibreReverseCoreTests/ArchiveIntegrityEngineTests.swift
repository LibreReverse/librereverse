#if os(macOS)
import CryptoKit
import Foundation
import Darwin
import XCTest
@testable import LibreReverseCore

final class ArchiveIntegrityEngineTests: XCTestCase {
    /// Opt-in and run alone so peak process memory measures this large hash.
    func testLargeFileHashUsesBoundedMemory() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_TEST_LARGE_HASH"] == "1" else {
            throw XCTSkip("Set LIBREREVERSE_TEST_LARGE_HASH=1 for the isolated 5 GiB memory regression.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let bytes: Int64 = 5121 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(bytes))
        try writer.close()
        var expected = SHA256()
        let zeroes = Data(repeating: 0, count: 1024 * 1024)
        for _ in 0..<5121 { expected.update(data: zeroes) }
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let actual = try await ArchiveIntegrityEngine.hashInBackground(file: file)
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        XCTAssertEqual(actual.byteCount, bytes)
        XCTAssertEqual(actual.sha256, S3SignatureV4.hex(expected.finalize()))
        print("Large hash peak RSS bytes: before=\(before.ru_maxrss), after=\(after.ru_maxrss)")
        XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, 128 * 1024 * 1024,
            "Hashing must release each FileHandle buffer instead of retaining the entire shard")
    }

    func testBackgroundHashMatchesWholeFileDigestAcrossBlocks() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<(4 * 1024 * 1024 + 137)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        let actual = try await ArchiveIntegrityEngine.hashInBackground(file: file)
        XCTAssertEqual(actual.byteCount, Int64(bytes.count))
        XCTAssertEqual(actual.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func testCancelledBackgroundHashDoesNotOpenFile() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArchiveIntegrityEngine.hashInBackground(
                file: URL(fileURLWithPath: "/nonexistent-cancelled-archive-input"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled archive work must not start file IO")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testOptInSynchronousHashCancellationPreservesDefaultCallers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("archive".utf8).write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            // Existing callers may deliberately finish a durable operation.
            XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: file).byteCount, 7)
            XCTAssertThrowsError(try ArchiveIntegrityEngine.hash(file: file, checkCancellation: true)) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        try await task.value
    }
}
#endif
