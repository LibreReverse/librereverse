#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

/// Explicit opt-in: only synthetic data in a new random library namespace.
final class S3ArchiveLiveTests: XCTestCase {
    private enum SimulatedInterruption: Error { case stopped }
    private actor SavedProgress {
        var latest: ArchiveUploadSession?
        var interrupted = false
        func save(_ value: ArchiveUploadSession) throws {
            latest = value
            print("S3 live: acknowledged \(value.acknowledgedBytes) / \(value.totalBytes) bytes")
            if !interrupted && value.acknowledgedBytes > 0 && value.acknowledgedBytes < value.totalBytes {
                interrupted = true
                throw SimulatedInterruption.stopped
            }
        }
    }
    func testLiveLargeFileRoundTripAndScopedCleanup() async throws {
        guard ProcessInfo.processInfo.environment["LIBREREVERSE_TEST_S3_LIVE"] == "1" else {
            throw XCTSkip("Set LIBREREVERSE_TEST_S3_LIVE=1 to run the isolated S3 integration test.")
        }
        let configuration = try XCTUnwrap(S3ArchiveConfigurationStore.environmentConfiguration(),
            "The four required S3 environment variables must be available.")
        let libraryID = UUID().uuidString.lowercased()
        let requestedMiB = Int(ProcessInfo.processInfo.environment["LIBREREVERSE_TEST_S3_MIB"] ?? "9") ?? 9
        guard requestedMiB >= 9 && requestedMiB <= 6144 else {
            throw XCTSkip("Live fixture size must be between 9 and 6144 MiB.")
        }
        let partBytes: Int64 = requestedMiB > 64 ? 64 * 1024 * 1024 : 5 * 1024 * 1024
        let backend = try S3ArchiveBackend(configuration: configuration, libraryID: libraryID,
            multipartThresholdBytes: 5 * 1024 * 1024, multipartPartBytes: partBytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s3-live-" + libraryID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let writer = try FileHandle(forWritingTo: source)
        var hash = SHA256()
        // Generate and hash bounded blocks; the large opt-in run uses 5121 MiB (>5 GiB).
        var block = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        for index in 0..<requestedMiB {
            // Distinct block markers expose skipped, repeated, or reordered ranges.
            var marker = UInt64(index).littleEndian
            withUnsafeBytes(of: &marker) { block.replaceSubrange(0..<8, with: $0) }
            try writer.write(contentsOf: block); hash.update(data: block)
        }
        try writer.close()
        let expected = ArchiveIntegrity(byteCount: Int64(requestedMiB) * 1024 * 1024,
            sha256: S3SignatureV4.hex(hash.finalize()))
        let key = ArchiveObjectKey("libraries/\(libraryID)/integration/large-file.bin")
        do {
            print("S3 live: connection probe")
            try await backend.validateConnection()
            print("S3 live: large upload")
            let upload = try await backend.beginUpload(.init(key: key, displayName: "synthetic fixture",
                objectKind: .databaseShard, subjectID: 1, relativePath: "large-file.bin",
                contentType: "application/octet-stream", integrity: expected))
            let saved = SavedProgress()
            do {
                _ = try await backend.resumeUpload(upload, from: source) { try await saved.save($0) }
                XCTFail("Expected an interruption after the first accepted part")
            } catch SimulatedInterruption.stopped { }
            let persisted = await saved.latest
            let checkpoint = try XCTUnwrap(persisted)
            XCTAssertGreaterThan(checkpoint.acknowledgedBytes, 0)
            XCTAssertLessThan(checkpoint.acknowledgedBytes, expected.byteCount)
            // Recreate the backend and round-trip the durable token as an app restart would.
            let resumed = try JSONDecoder().decode(ArchiveUploadSession.self,
                from: JSONEncoder().encode(checkpoint))
            let restarted = try S3ArchiveBackend(configuration: configuration, libraryID: libraryID)
            print("S3 live: resuming after persisted part checkpoint")
            let result = try await restarted.resumeUpload(resumed, from: source) { try await saved.save($0) }
            let finalProgress = await saved.latest
            XCTAssertEqual(finalProgress?.acknowledgedBytes, expected.byteCount)
            print("S3 live: verification")
            let verified = try await backend.verify(result.metadata, expected: expected)
            XCTAssertTrue(verified.matches)
            print("S3 live: explicit download")
            let download = root.appendingPathComponent("download.bin")
            try await backend.download(verified.metadata, to: download, progress: { _ in })
            let hydrated = try await ArchiveIntegrityEngine.hashInBackground(file: download)
            XCTAssertEqual(hydrated, expected)
            // Delete the explicit version first, then exercise scoped root cleanup.
            print("S3 live: cleanup")
            try await backend.remove(verified.metadata)
            try await backend.removeArchiveRoot()
            let remaining = try await backend.locate(key)
            XCTAssertNil(remaining)
        } catch {
            do { try await backend.removeArchiveRoot() }
            catch { XCTFail("Cleanup of the isolated S3 test namespace failed.") }
            throw error
        }
    }
}
#endif
