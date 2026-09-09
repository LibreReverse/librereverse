#if os(macOS)
import XCTest
@testable import LibreReverseCore

final class ArchiveProviderLifecycleTests: XCTestCase {
    private func fixture() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/key"), mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(library)
        return (root, library)
    }

    func testS3CredentialsRoundTripInEncryptedLibraryAndCanBeRemoved() throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try S3ArchiveConfiguration(endpoint: URL(string: "https://s3.example.invalid")!,
            bucket: "test-bucket", accessKey: "fixture-access-key", secretKey: "fixture-secret-never-plaintext")
        let store = S3ArchiveConfigurationStore(library: library)
        XCTAssertNil(try store.load())
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
        let bytes = try Data(contentsOf: library.databaseURL)
        XCTAssertNil(bytes.range(of: Data(config.secretKey.utf8)))
        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testS3EnvironmentRequiresCompleteConfigurationAndUsesOptionalRegion() throws {
        XCTAssertNil(try S3ArchiveConfigurationStore.environmentConfiguration(["S3_KEY": "key"]))
        let config = try XCTUnwrap(S3ArchiveConfigurationStore.environmentConfiguration([
            "S3_KEY": "fixture-key", "S3_SECRET": "fixture-secret", "S3_URL": "https://s3.example.invalid/",
            "S3_BUCKET": "test-bucket", "S3_REGION": "eu-west-1"
        ]))
        XCTAssertEqual(config.region, "eu-west-1")
        XCTAssertEqual(config.endpoint.absoluteString, "https://s3.example.invalid")
    }

    func testRetiredResolversRejectNewRequestsBeforeTouchingAnotherDestination() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try S3ArchiveBackend(configuration: .init(endpoint: URL(string: "https://s3.example.invalid")!,
            bucket: "test", accessKey: "fixture-key", secretKey: "fixture-secret"),
            libraryID: LibreReverseArchiveStore.libraryUUID(configuration: library))
        let media = LibreReverseLocalMediaResolver(destinationID: 1, library: library, backend: backend)
        let shards = LibreReverseShardResolver(destinationID: 1, library: library, backend: backend)
        await media.cancelAllAndWait()
        await shards.cancelAllAndWait()
        do { _ = try await media.resolve(videoID: 123); XCTFail("Retired media resolver accepted work") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await shards.restore(ordinal: 123) { _ in }; XCTFail("Retired shard resolver accepted work") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private actor MissingDownload: LibreReverseArchiveDownloading {
        var attempts = 0
        var isAvailable = false
        func makeAvailable() { isAvailable = true }
        func download(_ request: LibreReverseDownloadRequest,
                      progress: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void) async throws {
            attempts += 1
            if !isAvailable { throw LibreReverseShardArchiveError.shardUnavailable(1) }
        }
    }

    func testHistoryUnavailableInProviderParksUntilSwitchInsteadOfRetryingForever() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = LibreReverseArchiveDownloadCoordinator(library: library, retrySeconds: 0.01)
        let worker = MissingDownload()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await queue.connect(worker)
        try await queue.enqueue(date: date)
        for _ in 0..<500 {
            if try await queue.status(at: date)?.phase == .unavailable { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let phase = try await queue.status(at: date)?.phase
        XCTAssertEqual(phase, .unavailable)
        try await Task.sleep(nanoseconds: 250_000_000)
        let attempts = await worker.attempts
        XCTAssertEqual(attempts, 1)
        await worker.makeAvailable()
        try await queue.connect(worker)
        for _ in 0..<500 {
            if try await queue.status(at: date)?.phase == .complete { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let resumedPhase = try await queue.status(at: date)?.phase
        XCTAssertEqual(resumedPhase, .complete)
        await queue.pause(needsConnection: false)
    }

    private actor DrainingDownload: LibreReverseArchiveDownloading {
        var started = false
        var drained = false
        func download(_ request: LibreReverseDownloadRequest,
                      progress: @escaping @Sendable (LibreReverseDownloadStatus) async -> Void) async throws {
            started = true
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch {
                // Cleanup must complete before a replacement provider starts.
                await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
                drained = true
                throw CancellationError()
            }
        }
    }

    func testPauseWaitsForOldProviderDownloadCleanup() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = LibreReverseArchiveDownloadCoordinator(library: library)
        let worker = DrainingDownload()
        try await queue.connect(worker)
        try await queue.enqueue(date: Date(timeIntervalSince1970: 1_700_000_000))
        for _ in 0..<500 {
            if await worker.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await worker.started
        XCTAssertTrue(started)
        await queue.pause(needsConnection: false)
        let drained = await worker.drained
        XCTAssertTrue(drained)
    }
}
#endif
