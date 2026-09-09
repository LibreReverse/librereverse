#if os(macOS)
import CSQLCipher
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseShardArchiveTests: XCTestCase {
    private actor FakeBackend: ArchiveBackend {
        nonisolated let kind: ArchiveBackendKind = .googleDrive
        private var objects: [ArchiveObjectKey: Data] = [:]
        private var requests: [ArchiveUploadRequest] = []
        private var corruptDownloads = false
        private var downloadCount = 0
        private var downloadDelay: UInt64 = 0
        private var pauseVerification = false
        private var verificationResume: CheckedContinuation<Void, Never>?
        private var verificationStarted: CheckedContinuation<Void, Never>?

        func pauseNextVerification() { pauseVerification = true }
        func waitForPausedVerification() async {
            if verificationResume != nil { return }
            await withCheckedContinuation { verificationStarted = $0 }
        }
        func resumeVerification() {
            verificationResume?.resume()
            verificationResume = nil
        }

        func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata? {
            objects[key].map { metadata(key: key, data: $0) }
        }

        func beginUpload(_ request: ArchiveUploadRequest) async throws -> ArchiveUploadSession {
            requests.append(request)
            return .init(identifier: "fake://\(request.key.value)", key: request.key, totalBytes: request.integrity.byteCount)
        }

        func resumeUpload(
            _ session: ArchiveUploadSession,
            from file: URL,
            checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void
        ) async throws -> ArchiveUploadResult {
            let data = try Data(contentsOf: file)
            try await checkpoint(.init(
                identifier: session.identifier, key: session.key,
                acknowledgedBytes: Int64(data.count), totalBytes: Int64(data.count)
            ))
            objects[session.key] = data
            return .init(metadata: metadata(key: session.key, data: data))
        }

        func verify(
            _ metadata: RemoteObjectMetadata,
            expected: ArchiveIntegrity
        ) async throws -> RemoteVerification {
            guard let data = objects[metadata.key] else { throw ArchiveBackendError.invalidResponse }
            let current = self.metadata(key: metadata.key, data: data)
            if pauseVerification {
                pauseVerification = false
                await withCheckedContinuation { continuation in
                    verificationResume = continuation
                    verificationStarted?.resume()
                    verificationStarted = nil
                }
            }
            return .init(
                metadata: current,
                matches: current.byteCount == expected.byteCount && current.sha256 == expected.sha256
            )
        }

        func download(
            _ metadata: RemoteObjectMetadata,
            to temporaryURL: URL,
            progress: @Sendable (Int64) async -> Void
        ) async throws {
            downloadCount += 1
            if downloadDelay > 0 { try await Task.sleep(nanoseconds: downloadDelay) }
            guard let stored = objects[metadata.key] else { throw ArchiveBackendError.invalidResponse }
            let data = corruptDownloads ? Data(repeating: 0xff, count: stored.count) : stored
            try data.write(to: temporaryURL)
            await progress(Int64(data.count))
        }

        func downloads() -> Int { downloadCount }
        func setDownloadDelay(_ value: UInt64) { downloadDelay = value }
        func savedRequests() -> [ArchiveUploadRequest] { requests }
        func setCorruptDownloads(_ value: Bool) { corruptDownloads = value }

        private func metadata(key: ArchiveObjectKey, data: Data) -> RemoteObjectMetadata {
            .init(
                identifier: "remote-\(key.value)", version: "1", key: key,
                byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    func testShardEvictionDiscoverySharesUnlockAndSeesNewDownloadProtection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = fixture.configuration
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        XCTAssertNotNil(try LibreReverseArchiveStore.policy(
            destinationID: fixture.destinationID, configuration: configuration, session: session))
        let records = try LibreReverseShardStore.records(configuration: configuration, session: session)
        XCTAssertEqual(records, try LibreReverseShardStore.records(configuration: configuration))
        let store = LibreReverseDownloadRequestStore(library: configuration)
        XCTAssertTrue(try store.load(session: session).isEmpty)
        let request = LibreReverseDownloadRequest(date: Date(), shardOrdinal: records.first?.interval.ordinal)
        try store.save(request)
        XCTAssertEqual(try store.load(session: session), [request])
        XCTAssertEqual(session.connectionOpenCount, 1)
    }

    func testShardUploadIsTypedVerifiedAndCanBeRehydratedAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseShardArchiveCoordinator(
            destinationID: fixture.destinationID,
            library: fixture.configuration,
            backend: backend
        )

        let completed = try await coordinator.runUntilIdle()
        XCTAssertEqual(completed, 1)
        let opens = await coordinator.lastRunDatabaseOpenCount
        XCTAssertEqual(opens, 1, "Claim, checkpoints and verified state must share one keyed connection")
        let idleCompleted = try await coordinator.runUntilIdle()
        XCTAssertEqual(idleCompleted, 0)
        let idleOpens = await coordinator.lastRunDatabaseOpenCount
        XCTAssertEqual(idleOpens, 1, "A new idle run must use its own bounded connection")
        let status = try LibreReverseShardArchiveStore.status(
            destinationID: fixture.destinationID,
            configuration: fixture.configuration
        )
        XCTAssertEqual(status.totalObjects, 1)
        XCTAssertEqual(status.verifiedObjects, 1)
        XCTAssertEqual(status.queuedObjects, 0)
        XCTAssertEqual(status.failedObjects, 0)
        XCTAssertEqual(status.totalBytes, Int64(fixture.payload.count))
        XCTAssertEqual(status.verifiedBytes, Int64(fixture.payload.count))
        XCTAssertEqual(status.activeTransferredBytes, 0)
        let requests = await backend.savedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.objectKind, .databaseShard)
        XCTAssertEqual(request.subjectID, fixture.shardID)
        XCTAssertEqual(request.contentType, "application/octet-stream")

        try LibreReverseArchiveStore.updatePolicy(
            .init(
                coverageMode: .allHistory,
                continuousArchive: true,
                requiredLocalSeconds: 7 * 86_400
            ),
            destinationID: fixture.destinationID,
            configuration: fixture.configuration
        )
        let record = try XCTUnwrap(LibreReverseShardStore.records(
            configuration: fixture.configuration
        ).first)
        let residency = LibreReverseShardResidencyManager(
            destinationID: fixture.destinationID,
            library: fixture.configuration,
            backend: backend
        )
        let evicted = try await residency.evictEligible(
            now: record.interval.end.addingTimeInterval(8 * 86_400)
        )
        XCTAssertEqual(evicted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shardURL.path))
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: nil),
            destinationID: fixture.destinationID,
            configuration: fixture.configuration
        )
        XCTAssertEqual(
            try LibreReverseShardArchiveStore.ordinalsNeedingPolicyRehydration(
                destinationID: fixture.destinationID,
                configuration: fixture.configuration
            ),
            [0]
        )
        let resolver = LibreReverseShardResolver(
            destinationID: fixture.destinationID,
            library: fixture.configuration,
            backend: backend
        )
        let restored = try await resolver.restore(ordinal: 0) { _ in }
        XCTAssertEqual(try Data(contentsOf: restored), fixture.payload)
        XCTAssertEqual(
            try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state,
            .sealedLocal
        )
        XCTAssertTrue(try LibreReverseShardArchiveStore.ordinalsNeedingPolicyRehydration(
            destinationID: fixture.destinationID,
            configuration: fixture.configuration
        ).isEmpty)
    }

    func testCorruptShardDownloadIsRejectedAndRemainsRemoteOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseShardArchiveCoordinator(
            destinationID: fixture.destinationID,
            library: fixture.configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try FileManager.default.removeItem(at: fixture.shardURL)
        try markRemoteOnly(fixture)
        await backend.setCorruptDownloads(true)
        let resolver = LibreReverseShardResolver(
            destinationID: fixture.destinationID,
            library: fixture.configuration,
            backend: backend
        )
        do {
            _ = try await resolver.restore(ordinal: 0) { _ in }
            XCTFail("Expected corrupt download to fail")
        } catch {
            XCTAssertEqual(
                error as? LibreReverseShardArchiveError,
                .localIntegrityMismatch(0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shardURL.path))
        XCTAssertEqual(
            try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state,
            .remoteOnly
        )
    }

    func testAbandonedDownloadRestartsWithoutManualDatabaseRepair() async throws {
        let backend = FakeBackend()
        let fixture = try await makeRemoteFixture(backend)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try LibreReverseShardArchiveStore.setShardState(
            shardID: fixture.shardID, from: .remoteOnly, to: .rehydrating,
            configuration: fixture.configuration
        )
        let resolver = LibreReverseShardResolver(destinationID: fixture.destinationID,
                                             library: fixture.configuration, backend: backend)
        _ = try await resolver.restore(ordinal: 0) { _ in }
        XCTAssertEqual(try Data(contentsOf: fixture.shardURL), fixture.payload)
        XCTAssertEqual(try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state, .sealedLocal)
    }

    func testInstalledFileRecoversInterruptedResidencyCommitWithoutRedownload() async throws {
        let backend = FakeBackend()
        let fixture = try await makeRemoteFixture(backend)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.payload.write(to: fixture.shardURL)
        try LibreReverseShardArchiveStore.setShardState(
            shardID: fixture.shardID, from: .remoteOnly, to: .rehydrating,
            configuration: fixture.configuration
        )
        let resolver = LibreReverseShardResolver(destinationID: fixture.destinationID,
                                             library: fixture.configuration, backend: backend)
        _ = try await resolver.restore(ordinal: 0) { _ in }
        let count = await backend.downloads()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state, .sealedLocal)
    }

    func testSeparateResolversSerializeTheSameArchive() async throws {
        let backend = FakeBackend()
        let fixture = try await makeRemoteFixture(backend)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await backend.setDownloadDelay(200_000_000)
        let first = LibreReverseShardResolver(destinationID: fixture.destinationID,
                                          library: fixture.configuration, backend: backend)
        let second = LibreReverseShardResolver(destinationID: fixture.destinationID,
                                           library: fixture.configuration, backend: backend)
        async let one = first.restore(ordinal: 0) { _ in }
        async let two = second.restore(ordinal: 0) { _ in }
        let urls = try await [one, two]
        XCTAssertEqual(urls, [fixture.shardURL, fixture.shardURL])
        let count = await backend.downloads()
        XCTAssertEqual(count, 1)
    }

    func testStagingDirectoryFailureDoesNotLeaveDownloadingState() async throws {
        let backend = FakeBackend()
        let fixture = try await makeRemoteFixture(backend)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staging = fixture.configuration.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("ShardRehydration")
        try Data("blocks directory creation".utf8).write(to: staging)
        let resolver = LibreReverseShardResolver(destinationID: fixture.destinationID,
                                             library: fixture.configuration, backend: backend)
        do {
            _ = try await resolver.restore(ordinal: 0) { _ in }
            XCTFail("Expected staging failure")
        } catch {}
        XCTAssertEqual(try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state, .remoteOnly)
    }

    func testEvictionRetainsReplacementInstalledWhileRemoteVerificationIsSuspended() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = FakeBackend()
        let uploader = LibreReverseShardArchiveCoordinator(
            destinationID: fixture.destinationID, library: fixture.configuration, backend: backend)
        _ = try await uploader.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 7 * 86_400), destinationID: fixture.destinationID,
            configuration: fixture.configuration)
        let record = try XCTUnwrap(LibreReverseShardStore.records(configuration: fixture.configuration).first)
        let residency = LibreReverseShardResidencyManager(
            destinationID: fixture.destinationID, library: fixture.configuration, backend: backend)
        await backend.pauseNextVerification()
        let eviction = Task {
            try await residency.evictEligible(now: record.interval.end.addingTimeInterval(8 * 86_400))
        }
        await backend.waitForPausedVerification()
        do {
            // Simulate a completed shard rewrite while the old remote bytes are
            // being verified. It installs a new local payload and queues upload.
            let replacement = Data("new shard content".utf8)
            try replacement.write(to: fixture.shardURL, options: .atomic)
            let integrity = try ArchiveIntegrityEngine.hash(file: fixture.shardURL)
            try execute("""
                BEGIN IMMEDIATE;
                UPDATE library_shard SET sha256='\(integrity.sha256)',byteCount=\(integrity.byteCount)
                 WHERE id=\(fixture.shardID);
                UPDATE shard_archive_object SET remoteState='queued',remoteIdentifier=NULL,
                  remoteVersion=NULL,remoteSHA256=NULL,totalBytes=\(integrity.byteCount)
                 WHERE shardId=\(fixture.shardID);
                COMMIT;
                """, configuration: fixture.configuration)
            await backend.resumeVerification()
            do {
                _ = try await eviction.value
                XCTFail("Stale verification must not evict the replacement")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("changed during archive verification"))
            }
            XCTAssertEqual(try Data(contentsOf: fixture.shardURL), replacement)
            XCTAssertEqual(try LibreReverseShardStore.records(configuration: fixture.configuration).first?.state, .sealedLocal)
        } catch {
            await backend.resumeVerification()
            _ = try? await eviction.value
            throw error
        }
    }

    private func makeRemoteFixture(_ backend: FakeBackend) async throws -> Fixture {
        let fixture = try makeFixture()
        let coordinator = LibreReverseShardArchiveCoordinator(destinationID: fixture.destinationID,
                                                           library: fixture.configuration, backend: backend)
        _ = try await coordinator.runUntilIdle()
        try FileManager.default.removeItem(at: fixture.shardURL)
        try markRemoteOnly(fixture)
        return fixture
    }

    private func markRemoteOnly(_ fixture: Fixture) throws {
        let record = try XCTUnwrap(LibreReverseShardStore.records(configuration: fixture.configuration).first)
        let remote = try XCTUnwrap(LibreReverseShardArchiveStore.remoteShard(
            ordinal: record.interval.ordinal, destinationID: fixture.destinationID,
            configuration: fixture.configuration))
        try LibreReverseShardArchiveStore.markRemoteOnlyIfUnchanged(
            remote, destinationID: fixture.destinationID, configuration: fixture.configuration)
    }

    private struct Fixture {
        let root: URL
        let configuration: LibreReverseLibraryConfiguration
        let destinationID: Int64
        let shardID: Int64
        let shardURL: URL
        let payload: Data
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-archive-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive", remoteRoot: "root", configuration: configuration
        )
        let epoch = try LibreReverseShardStore.epochStart(configuration: configuration)
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let relativePath = "Shards/\(interval.fileName)"
        let shardURL = configuration.databaseURL.deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: shardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute(
            """
            CREATE VIRTUAL TABLE searchRanking
              USING fts5(text,otherText,title,tokenize=porter);
            CREATE VIRTUAL TABLE search
              USING fts4(text,otherText,tokenize=porter);
            CREATE VIRTUAL TABLE searchOffsets
              USING fts4(text,otherText,tokenize=porter);
            """,
            databaseURL: shardURL,
            keyFileURL: configuration.keyFileURL
        )
        let payload = try Data(contentsOf: shardURL)
        let integrity = try ArchiveIntegrityEngine.hash(file: shardURL)
        let shardID = try LibreReverseShardStore.registerBuildingShard(
            interval: interval, relativePath: relativePath, configuration: configuration
        )
        try LibreReverseShardStore.markSealedLocal(
            shardID: shardID, byteCount: integrity.byteCount, sha256: integrity.sha256,
            frameCount: 1, nodeCount: 0, documentCount: 0,
            minFrameID: 1, maxFrameID: 1, configuration: configuration
        )
        // Archive tests use opaque bytes to isolate transport semantics. A
        // production shard builder has already materialized this compact
        // availability row before residency is allowed to evict the payload.
        try execute(
            """
            INSERT INTO shard_calendar_hour(shardId,hourKey,sampleCreatedAt)
            VALUES(\(shardID),'1970-01-01T00','1970-01-01T00:00:00.000')
            """,
            configuration: configuration
        )
        return .init(
            root: root, configuration: configuration, destinationID: destinationID,
            shardID: shardID, shardURL: shardURL, payload: payload
        )
    }

    private func execute(
        _ sql: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try execute(
            sql,
            databaseURL: configuration.databaseURL,
            keyFileURL: configuration.keyFileURL
        )
    }

    private func execute(
        _ sql: String,
        databaseURL: URL,
        keyFileURL: URL
    ) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }, SQLITE_OK)
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(status)"
            sqlite3_free(error)
            throw NSError(domain: "LibreReverseShardArchiveTests", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }
}
#endif
