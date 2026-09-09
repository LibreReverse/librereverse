#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseArchiveCoordinatorTests: XCTestCase {
    func testAdaptiveConcurrencyUsesAdditiveIncreaseAndThrottleHalving() {
        var window = LibreReverseAdaptiveConcurrencyWindow(initial: 4, maximum: 16)
        window.record(completed: true, throttled: false, admittedGeneration: 0)
        XCTAssertEqual(window.limit, 5, "the unpressured probe should ramp quickly")

        window.record(completed: false, throttled: true, admittedGeneration: 0)
        XCTAssertEqual(window.limit, 2)
        XCTAssertEqual(window.generation, 1)
        window.record(completed: true, throttled: false, admittedGeneration: 1)
        XCTAssertEqual(window.limit, 2)
        window.record(completed: true, throttled: false, admittedGeneration: 1)
        XCTAssertEqual(window.limit, 3)

        window.record(completed: false, throttled: true, admittedGeneration: 1)
        XCTAssertEqual(window.limit, 1)
        window.record(completed: false, throttled: true, admittedGeneration: 1)
        XCTAssertEqual(window.limit, 1)
        XCTAssertEqual(window.generation, 2, "the same flight must only reduce once")

        for _ in 0..<1_000 {
            window.record(
                completed: true,
                throttled: false,
                admittedGeneration: window.generation
            )
        }
        XCTAssertEqual(window.limit, 16)
    }

    func testAdaptiveConcurrencyDefaultsProbeQuicklyFromProvenSixteenToSixtyFour() {
        var window = LibreReverseAdaptiveConcurrencyWindow()
        XCTAssertEqual(window.limit, 16)
        XCTAssertEqual(window.maximum, 64)

        for expectedLimit in 17...64 {
            window.record(completed: true, throttled: false, admittedGeneration: 0)
            XCTAssertEqual(window.limit, expectedLimit)
        }

        for _ in 0..<64 {
            window.record(completed: true, throttled: false, admittedGeneration: 0)
        }
        XCTAssertEqual(window.limit, 64)
    }

    private actor ProgressCollector {
        private var values: [LibreReverseDayRestoreProgress] = []
        func append(_ value: LibreReverseDayRestoreProgress) { values.append(value) }
        func snapshot() -> [LibreReverseDayRestoreProgress] { values }
    }

    private actor FakeBackend: ArchiveBackend {
        nonisolated let kind: ArchiveBackendKind = .googleDrive
        var objects: [ArchiveObjectKey: Data] = [:]
        var requests: [ArchiveObjectKey: ArchiveUploadRequest] = [:]
        var checkpoints: [Int64] = []
        var forceVerificationMismatch = false
        var downloadCount = 0
        var activeDownloads = 0
        var maximumActiveDownloads = 0
        var downloadDelayNanoseconds: UInt64 = 50_000_000
        var expireNextUpload = false
        var beginUploadCount = 0
        var activeUploads = 0
        var maximumActiveUploads = 0
        var uploadDelayNanoseconds: UInt64 = 0
        var rateLimitedUploadsRemaining = 0
        var resumeUploadCount = 0
        var corruptDownloads = false
        var missingDownloadStatus: Int?

        func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata? {
            guard let bytes = objects[key] else { return nil }
            return metadata(key, bytes)
        }

        func beginUpload(_ request: ArchiveUploadRequest) async throws -> ArchiveUploadSession {
            beginUploadCount += 1
            requests[request.key] = request
            return .init(identifier: "fake://\(request.key.value)", key: request.key, totalBytes: request.integrity.byteCount)
        }

        func resumeUpload(
            _ session: ArchiveUploadSession,
            from file: URL,
            checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void
        ) async throws -> ArchiveUploadResult {
            resumeUploadCount += 1
            activeUploads += 1
            maximumActiveUploads = max(maximumActiveUploads, activeUploads)
            defer { activeUploads -= 1 }
            if uploadDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: uploadDelayNanoseconds)
            }
            if rateLimitedUploadsRemaining > 0 {
                rateLimitedUploadsRemaining -= 1
                throw ArchiveBackendError.rateLimited(
                    status: 429,
                    message: "synthetic Drive pressure"
                )
            }
            if expireNextUpload {
                expireNextUpload = false
                throw ArchiveBackendError.expiredUploadSession
            }
            let bytes = try Data(contentsOf: file)
            let midpoint = Int64(bytes.count / 2)
            checkpoints.append(midpoint)
            try await checkpoint(.init(identifier: session.identifier, key: session.key, acknowledgedBytes: midpoint, totalBytes: session.totalBytes))
            objects[session.key] = bytes
            checkpoints.append(Int64(bytes.count))
            try await checkpoint(.init(identifier: session.identifier, key: session.key, acknowledgedBytes: Int64(bytes.count), totalBytes: session.totalBytes))
            return .init(metadata: metadata(session.key, bytes))
        }

        func verify(_ remote: RemoteObjectMetadata, expected: ArchiveIntegrity) async throws -> RemoteVerification {
            guard let bytes = objects[remote.key] else { throw ArchiveBackendError.invalidResponse }
            let found = metadata(remote.key, bytes)
            return .init(
                metadata: found,
                matches: !forceVerificationMismatch
                    && found.byteCount == expected.byteCount
                    && found.sha256 == expected.sha256
            )
        }

        func download(
            _ remote: RemoteObjectMetadata,
            to temporaryURL: URL,
            progress: @Sendable (Int64) async -> Void
        ) async throws {
            if let missingDownloadStatus {
                throw ArchiveBackendError.requestFailed(
                    status: missingDownloadStatus,
                    message: "remote object is unavailable"
                )
            }
            guard let bytes = objects[remote.key] else { throw ArchiveBackendError.invalidResponse }
            downloadCount += 1
            activeDownloads += 1
            maximumActiveDownloads = max(maximumActiveDownloads, activeDownloads)
            defer { activeDownloads -= 1 }
            try await Task.sleep(nanoseconds: downloadDelayNanoseconds)
            let downloaded = corruptDownloads ? Data(repeating: 0xff, count: bytes.count) : bytes
            try downloaded.write(to: temporaryURL)
            await progress(Int64(downloaded.count))
        }

        func setVerificationMismatch(_ value: Bool) { forceVerificationMismatch = value }
        func savedCheckpointValues() -> [Int64] { checkpoints }
        func savedDownloadCount() -> Int { downloadCount }
        func savedMaximumActiveDownloads() -> Int { maximumActiveDownloads }
        func setDownloadDelayNanoseconds(_ value: UInt64) { downloadDelayNanoseconds = value }
        func setExpireNextUpload() { expireNextUpload = true }
        func savedBeginUploadCount() -> Int { beginUploadCount }
        func savedMaximumActiveUploads() -> Int { maximumActiveUploads }
        func setUploadDelayNanoseconds(_ value: UInt64) { uploadDelayNanoseconds = value }
        func setRateLimitedUploadsRemaining(_ value: Int) {
            rateLimitedUploadsRemaining = value
        }
        func savedResumeUploadCount() -> Int { resumeUploadCount }
        func setCorruptDownloads(_ value: Bool) { corruptDownloads = value }
        func setMissingDownloadStatus(_ value: Int?) { missingDownloadStatus = value }
        func removeRemoteObject(_ key: ArchiveObjectKey) { objects[key] = nil }

        private func metadata(_ key: ArchiveObjectKey, _ bytes: Data) -> RemoteObjectMetadata {
            .init(
                identifier: "remote-\(key.value)",
                version: "1",
                key: key,
                byteCount: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    func testCoordinatorHashesUploadsCheckpointsAndIndependentlyVerifies() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
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
        let object = try XCTUnwrap(LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        ).first)
        XCTAssertEqual(object.remoteState, .verified)
        XCTAssertNotNil(object.localSHA256)
        let checkpoints = await backend.savedCheckpointValues()
        XCTAssertEqual(checkpoints, [2, 5])
        let status = try await coordinator.snapshot().status
        XCTAssertEqual(status.verifiedObjects, 1)
        XCTAssertEqual(status.verifiedBytes, 5)
        XCTAssertNotNil(status.latestVerifiedAt)
    }

    func testCancelledUploadClosesSessionBeforeNextPrimaryIsInstalled() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        await backend.setUploadDelayNanoseconds(60_000_000_000)
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID, library: configuration, backend: backend)
        let run = Task { try await coordinator.runUntilIdle() }
        var started = false
        for _ in 0..<200 {
            if await backend.savedResumeUploadCount() > 0 { started = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(started)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("Cancelled upload must propagate cancellation")
        } catch is CancellationError {}
        let active = await backend.activeUploads
        XCTAssertEqual(active, 0, "Run must drain its upload callbacks before returning")
        let failed = try XCTUnwrap(LibreReverseArchiveStore.objects(
            destinationID: destinationID, configuration: configuration).first)
        XCTAssertNotEqual(failed.remoteState, .verified)

        // The app performs this replacement only after awaiting the cancelled run.
        try FileManager.default.moveItem(at: configuration.databaseURL,
            to: root.appendingPathComponent("retired.sqlite3"))
        try LibreReverseLibraryStore.initialize(configuration)
        try LibreReverseArchiveStore.initialize(configuration)
        let completed = try await coordinator.runUntilIdle()
        XCTAssertEqual(completed, 0, "The next run must query the new primary, not the retired file")
    }

    func testCoordinatorBoundsParallelUploadsAndProcessesEveryClaimExactlyOnce() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...5 {
            let admitted = try LibreReverseLibraryStore.admitFrame(
                createdAt: Date().addingTimeInterval(Double(index)),
                imageFileName: "parallel-\(index).png",
                context: nil,
                configuration: configuration
            )
            let path = "202608/26/parallel-\(index)"
            try Data(repeating: UInt8(index), count: 32).write(
                to: configuration.mediaRoot.appendingPathComponent(path)
            )
            _ = try LibreReverseLibraryStore.commitRecordedChunk(
                .init(
                    relativeMediaPath: path,
                    xid: "parallel-\(index)",
                    width: 8,
                    height: 8,
                    frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
                ),
                configuration: configuration
            )
        }
        let backend = FakeBackend()
        await backend.setUploadDelayNanoseconds(100_000_000)
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            maximumConcurrentObjects: 3
        )

        let completed = try await coordinator.runUntilIdle()
        let maximumActiveUploads = await backend.savedMaximumActiveUploads()
        XCTAssertEqual(completed, 6)
        XCTAssertEqual(maximumActiveUploads, 3)
        let objects = try LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        )
        XCTAssertEqual(objects.count, 6)
        XCTAssertTrue(objects.allSatisfy { $0.remoteState == .verified })
    }

    func testDrivePressureDrainsOneFlightWithoutAdmittingMoreQueuedObjects() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...7 {
            let admitted = try LibreReverseLibraryStore.admitFrame(
                createdAt: Date().addingTimeInterval(Double(index)),
                imageFileName: "pressure-\(index).png",
                context: nil,
                configuration: configuration
            )
            let path = "202608/26/pressure-\(index)"
            try Data(repeating: UInt8(index), count: 32).write(
                to: configuration.mediaRoot.appendingPathComponent(path)
            )
            _ = try LibreReverseLibraryStore.commitRecordedChunk(
                .init(
                    relativeMediaPath: path,
                    xid: "pressure-\(index)",
                    width: 8,
                    height: 8,
                    frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
                ),
                configuration: configuration
            )
        }
        let backend = FakeBackend()
        await backend.setUploadDelayNanoseconds(50_000_000)
        await backend.setRateLimitedUploadsRemaining(4)
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            maximumConcurrentObjects: 64,
            initialConcurrentObjects: 4
        )

        let completed = try await coordinator.runUntilIdle()
        let resumeUploadCount = await backend.savedResumeUploadCount()
        let reducedLimit = await coordinator.currentConcurrencyLimit()
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(resumeUploadCount, 4)
        XCTAssertEqual(
            reducedLimit,
            2,
            "four 429s from one admitted flight are one pressure event"
        )
        let states = try LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        ).map(\.remoteState)
        XCTAssertEqual(states.filter { $0 == .retryWait }.count, 4)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 4)
    }

    func testVerificationMismatchIsNeverMarkedVerified() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        await backend.setVerificationMismatch(true)
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        let completed = try await coordinator.runUntilIdle()
        XCTAssertEqual(completed, 0)
        let object = try XCTUnwrap(LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        ).first)
        XCTAssertEqual(object.remoteState, .failed)
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.status.verifiedObjects, 0)
    }

    func testTerminalFailureDoesNotBlockLaterQueuedVideos() async throws {
        let (root, configuration, destinationID, firstVideoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let admitted = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(),
            imageFileName: "later.png",
            context: nil,
            configuration: configuration
        )
        try Data([6, 7, 8]).write(
            to: configuration.mediaRoot.appendingPathComponent("202608/26/later-xid")
        )
        let laterVideoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: "202608/26/later-xid",
                xid: "later-xid",
                width: 8,
                height: 8,
                frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
            ),
            configuration: configuration
        )
        try FileManager.default.removeItem(
            at: configuration.mediaRoot.appendingPathComponent("202608/26/queued-xid")
        )
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: FakeBackend()
        )

        let completed = try await coordinator.runUntilIdle()
        XCTAssertEqual(completed, 1)

        let states = Dictionary(uniqueKeysWithValues: try LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        ).map { ($0.videoID, $0.remoteState) })
        XCTAssertEqual(states[firstVideoID], .failed)
        XCTAssertEqual(states[laterVideoID], .verified)
    }

    func testExpiredResumableSessionIsDiscardedAndRestarted() async throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        await backend.setExpireNextUpload()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        let completed = try await coordinator.runUntilIdle()
        XCTAssertEqual(completed, 1)
        let beginCount = await backend.savedBeginUploadCount()
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first?.remoteState,
            .verified
        )
    }

    func testIntegrityEngineMatchesKnownSHA256WithoutLoadingWholeFileContract() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(
            try ArchiveIntegrityEngine.hash(file: url, chunkSize: 1),
            .init(byteCount: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        )
    }

    func testEvictionRequiresVerifiedRemoteAndRechecksCurrentLocalBytes() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 20 * 1024 * 1024 * 1024),
            destinationID: destinationID,
            configuration: configuration
        )
        let manager = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let canonical = configuration.mediaRoot.appendingPathComponent("202608/26/queued-xid")

        try Data([9, 9, 9, 9, 9]).write(to: canonical)
        let corruptEvictions = try await manager.evictEligible()
        XCTAssertEqual(corruptEvictions, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertEqual(
            try LibreReverseArchiveStore.residencyForecast(
                destinationID: destinationID,
                configuration: configuration
            ),
            .init(
                bytesSelectedForRemoval: 5,
                bytesSafelyEvictable: 0,
                bytesWaitingForVerification: 5
            )
        )

        try Data([1, 2, 3, 4, 5]).write(to: canonical)
        await backend.setVerificationMismatch(true)
        let staleRemoteEvictions = try await manager.evictEligible()
        XCTAssertEqual(staleRemoteEvictions, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first?.remoteState,
            .failed,
            "eviction must invalidate stale remote verification evidence"
        )

        await backend.setVerificationMismatch(false)
        try LibreReverseArchiveStore.retryFailedObjects(
            destinationID: destinationID,
            configuration: configuration
        )
        _ = try await coordinator.runUntilIdle()
        let validEvictions = try await manager.evictEligible()
        XCTAssertEqual(validEvictions, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first?.videoID,
            videoID,
            "eviction must retain timeline/archive identity"
        )
    }

    func testRehydratedCacheBudgetNeverProtectsOriginalRecordings() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 10),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            handoffGraceSeconds: 0
        )
        try LibreReverseArchiveStore.reconcileDesiredResidency(
            destinationID: destinationID,
            configuration: configuration
        )

        XCTAssertEqual(
            try LibreReverseArchiveStore.residencyForecast(
                destinationID: destinationID,
                configuration: configuration
            ),
            .init(
                bytesSelectedForRemoval: 5,
                bytesSafelyEvictable: 5,
                bytesWaitingForVerification: 0
            )
        )

        let originalEvictions = try await residency.evictEligible()
        XCTAssertEqual(originalEvictions, 1,
                       "the cache budget must not retain an original recording")
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await resolver.resolve(videoID: videoID)
        XCTAssertEqual(
            try LibreReverseArchiveStore.residencyForecast(
                destinationID: destinationID,
                configuration: configuration
            ).bytesSelectedForRemoval,
            0
        )
        let withinBudgetEvictions = try await residency.evictEligible()
        XCTAssertEqual(withinBudgetEvictions, 0,
                       "a rehydrated file inside the cache budget should stay local")

        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        try LibreReverseArchiveStore.reconcileDesiredResidency(
            destinationID: destinationID,
            configuration: configuration
        )
        XCTAssertEqual(
            try LibreReverseArchiveStore.residencyForecast(
                destinationID: destinationID,
                configuration: configuration
            ).bytesSafelyEvictable,
            0,
            "a restored recording stays protected until its new cache segment rolls over"
        )
        let shrunkenBudgetEvictions = try await residency.evictEligible()
        XCTAssertEqual(shrunkenBudgetEvictions, 0,
                       "policy cleanup must not fight a fresh rehydration segment")

        let afterNextSegmentBoundary = Date().addingTimeInterval(
            LibreReverseShardInterval.duration + 86_400
        )
        XCTAssertEqual(
            try LibreReverseArchiveStore.evictionBytesRequired(
                destinationID: destinationID,
                now: afterNextSegmentBoundary,
                configuration: configuration
            ),
            5,
            "the restored cache becomes automatic cleanup input after its 30-day segment"
        )
        XCTAssertEqual(
            try LibreReverseArchiveStore.evictionCandidates(
                destinationID: destinationID,
                accessedBefore: afterNextSegmentBoundary,
                now: afterNextSegmentBoundary,
                configuration: configuration
            ).map(\.videoID),
            [videoID]
        )
    }

    func testRemoteOnlyTimelineRemainsVisibleAndConcurrentSeeksCoalesceRehydration() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await residency.evictEligible()

        let historical = LibraryDatabaseConfiguration(
            databaseURL: configuration.databaseURL,
            keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot,
            frameImagesRoot: configuration.frameImagesRoot
        )
        XCTAssertEqual(try LibraryDatabase.loadChunks(configuration: historical).count, 1)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        async let first = resolver.resolve(videoID: videoID)
        async let second = resolver.resolve(videoID: videoID)
        let urls = try await [first, second]
        XCTAssertEqual(urls[0], urls[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        let downloads = await backend.savedDownloadCount()
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: urls[0]).byteCount, 5)
    }

    func testCorruptRehydrationNeverInstallsAndCanRetryCleanly() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await residency.evictEligible()
        let canonical = configuration.mediaRoot.appendingPathComponent("202608/26/queued-xid")
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        await backend.setCorruptDownloads(true)
        await XCTAssertThrowsErrorAsync(try await resolver.resolve(videoID: videoID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))

        await backend.setCorruptDownloads(false)
        let restored = try await resolver.resolve(videoID: videoID)
        XCTAssertEqual(restored, canonical)
        XCTAssertEqual(try ArchiveIntegrityEngine.hash(file: canonical).byteCount, 5)
    }

    func testMissingRemoteDuringRehydrationInvalidatesVerifiedState() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            handoffGraceSeconds: 0
        )
        _ = try await residency.evictEligible()
        await backend.setMissingDownloadStatus(404)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        await XCTAssertThrowsErrorAsync(try await resolver.resolve(videoID: videoID))

        let object = try XCTUnwrap(LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        ).first)
        XCTAssertEqual(object.remoteState, .failed)
        XCTAssertEqual(
            try LibreReverseArchiveStore.status(
                destinationID: destinationID,
                configuration: configuration
            ).failedObjects,
            1
        )
        XCTAssertTrue(try LibreReverseArchiveStore.videosNeedingRehydration(
            destinationID: destinationID,
            configuration: configuration
        ).isEmpty)
    }

    func testRehydrationBoundsCrossVideoDownloadsToConfiguredConcurrency() async throws {
        let (root, configuration, destinationID, firstVideoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        var videoIDs = [firstVideoID]
        for index in 2...3 {
            let admitted = try LibreReverseLibraryStore.admitFrame(
                createdAt: Date().addingTimeInterval(-Double(index)),
                imageFileName: "queued-\(index).png",
                context: nil,
                configuration: configuration
            )
            let path = "202608/26/queued-xid-\(index)"
            try Data(repeating: UInt8(index), count: 5).write(
                to: configuration.mediaRoot.appendingPathComponent(path)
            )
            videoIDs.append(try LibreReverseLibraryStore.commitRecordedChunk(
                .init(
                    relativeMediaPath: path,
                    xid: "queued-xid-\(index)",
                    width: 8,
                    height: 8,
                    frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
                ),
                configuration: configuration
            ))
        }
        let backend = FakeBackend()
        await backend.setDownloadDelayNanoseconds(1_000_000_000)
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).count,
            3,
            "every finalized video should be queued by the continuous policy"
        )
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let uploaded = try await coordinator.runUntilIdle()
        XCTAssertEqual(uploaded, 3)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let evicted = try await residency.evictEligible()
        XCTAssertEqual(evicted, 3)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            maximumConcurrentDownloads: 2
        )

        let firstID = videoIDs[0]
        let secondID = videoIDs[1]
        let thirdID = videoIDs[2]
        async let first = resolver.resolve(videoID: firstID)
        async let second = resolver.resolve(videoID: secondID)
        async let third = resolver.resolve(videoID: thirdID)
        _ = try await [first, second, third]
        let downloadCount = await backend.savedDownloadCount()
        let maximumDownloads = await backend.savedMaximumActiveDownloads()
        XCTAssertEqual(downloadCount, 3)
        XCTAssertEqual(maximumDownloads, 2)
    }

    func testExplicitDayRestoreReportsDeterminateProgressBeforeReturningMedia() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let uploaded = try await coordinator.runUntilIdle()
        XCTAssertEqual(uploaded, 1)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let evicted = try await residency.evictEligible()
        XCTAssertEqual(evicted, 1)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let progress = ProgressCollector()

        let restored = try await resolver.restoreDay(
            containing: Date(),
            selectedVideoID: videoID
        ) { await progress.append($0) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        let values = await progress.snapshot()
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.first?.completedBytes, 0)
        XCTAssertEqual(values.last?.completedBytes, values.last?.totalBytes)
        XCTAssertEqual(values.last?.totalBytes, 5)
        XCTAssertEqual(values.last?.currentRelativePath, "202608/26/queued-xid")
    }

    func testHourRestoreKeepsSelectedMediaWhenLaterNeighborFails() async throws {
        let (root, configuration, destinationID, selectedVideoID) = try makeQueuedVideo(createdAt: Date().addingTimeInterval(-10))
        defer { try? FileManager.default.removeItem(at: root) }
        let admitted = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date().addingTimeInterval(-9),
            imageFileName: "neighbor.png",
            context: nil,
            configuration: configuration
        )
        let neighborPath = "202608/26/neighbor-xid"
        try Data([7, 8, 9]).write(
            to: configuration.mediaRoot.appendingPathComponent(neighborPath)
        )
        let neighborVideoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: neighborPath,
                xid: "neighbor-xid",
                width: 8,
                height: 8,
                frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
            ),
            configuration: configuration
        )
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        let uploaded = try await coordinator.runUntilIdle()
        XCTAssertEqual(uploaded, 2)
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            handoffGraceSeconds: 0
        )
        let evicted = try await residency.evictEligible()
        XCTAssertEqual(evicted, 2)
        let neighbor = try XCTUnwrap(
            LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first(where: { $0.videoID == neighborVideoID })
        )
        await backend.removeRemoteObject(ArchiveObjectKey(neighbor.objectKey))
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        let restored = try await resolver.restoreDay(
            containing: Date(),
            selectedVideoID: selectedVideoID
        ) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
    }

    func testCursorTaskCancellationDoesNotCancelTargetedMediaTransfer() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            handoffGraceSeconds: 0
        )
        _ = try await residency.evictEligible()
        await backend.setDownloadDelayNanoseconds(300_000_000)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        let cursorRequest = Task {
            try await resolver.restoreMoment(videoID: videoID) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cursorRequest.cancel()

        let restored = try await cursorRequest.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
        let downloads = await backend.savedDownloadCount()
        XCTAssertEqual(downloads, 1)
    }

    func testResolverRemovesOnlyInterruptedPartialDownloadsAtStartup() throws {
        let (root, configuration, destinationID, _) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let rehydration = configuration.mediaRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Rehydration")
        try FileManager.default.createDirectory(at: rehydration, withIntermediateDirectories: true)
        let partial = rehydration.appendingPathComponent("orphan.partial")
        let unrelated = rehydration.appendingPathComponent("keep.txt")
        try Data([1]).write(to: partial)
        try Data([2]).write(to: unrelated)

        _ = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: FakeBackend()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testResolverCancellationNeverInstallsAPartialDownload() async throws {
        let (root, configuration, destinationID, videoID) = try makeQueuedVideo()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let coordinator = LibreReverseArchiveCoordinator(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )
        _ = try await coordinator.runUntilIdle()
        try LibreReverseArchiveStore.updatePolicy(
            .init(requiredLocalSeconds: 0, rehydratedCacheBytes: 0),
            destinationID: destinationID,
            configuration: configuration
        )
        let residency = LibreReverseMediaResidencyManager(
            destinationID: destinationID,
            library: configuration,
            backend: backend,
            handoffGraceSeconds: 0
        )
        _ = try await residency.evictEligible()
        let canonical = configuration.mediaRoot.appendingPathComponent("202608/26/queued-xid")
        await backend.setDownloadDelayNanoseconds(1_000_000_000)
        let resolver = LibreReverseLocalMediaResolver(
            destinationID: destinationID,
            library: configuration,
            backend: backend
        )

        let resolving = Task { try await resolver.resolve(videoID: videoID) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await resolver.cancelAll()
        await XCTAssertThrowsErrorAsync(try await resolving.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
    }

    private func makeQueuedVideo(createdAt: Date = Date()) throws -> (URL, LibreReverseLibraryConfiguration, Int64, Int64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-coordinator-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Fake Drive",
            remoteRoot: "fake-root",
            configuration: configuration
        )
        let admitted = try LibreReverseLibraryStore.admitFrame(
            createdAt: createdAt,
            imageFileName: "queued.png",
            context: nil,
            configuration: configuration
        )
        let path = "202608/26/queued-xid"
        let mediaURL = configuration.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: mediaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4, 5]).write(to: mediaURL)
        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: path,
                xid: "queued-xid",
                width: 8,
                height: 8,
                frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
            ),
            configuration: configuration
        )
        return (root, configuration, destinationID, videoID)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
#endif
