#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseArchiveStoreTests: XCTestCase {
    func testSchemaInitializationIsIdempotentAndPreservesRecoveryRecords() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try execute("""
            INSERT INTO meeting_deletion(segmentId,shardId,planJSON,state,createdAt,updatedAt)
              VALUES(42,7,x'7B7D','prepared','2026-08-01','2026-08-01');
            INSERT INTO meeting_title_update(segmentId,shardId,planJSON,state,createdAt,updatedAt)
              VALUES(43,8,x'7B7D','prepared','2026-08-01','2026-08-01');
            """, configuration)
        try LibreReverseArchiveStore.initialize(configuration)
        try LibreReverseArchiveStore.initialize(configuration)
        XCTAssertEqual(try scalar("PRAGMA user_version", configuration), 41)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM meeting_deletion WHERE segmentId=42 AND shardId=7", configuration), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM meeting_title_update WHERE segmentId=43 AND shardId=8", configuration), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_table_info('media_residency') WHERE name IN ('isCache','cacheRetainUntil')", configuration), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM archive_library", configuration), 1)
    }

    func testCredentialStoreRoundTripsUpdatesAndRemovesInsideEncryptedDatabase() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GoogleDriveEncryptedDatabaseStore(configuration: configuration)
        let account = "google-drive-refresh-token-test"
        let first = Data("plaintext-refresh-token-marker-one".utf8)
        let second = Data("plaintext-refresh-token-marker-two".utf8)

        XCTAssertNil(try store.data(account: account))
        try store.set(first, account: account)
        XCTAssertEqual(try store.data(account: account), first)
        try store.set(second, account: account)
        XCTAssertEqual(try store.data(account: account), second)

        let encryptedDatabase = try Data(contentsOf: configuration.databaseURL)
        XCTAssertNil(encryptedDatabase.range(of: first))
        XCTAssertNil(encryptedDatabase.range(of: second))
        XCTAssertNil(encryptedDatabase.range(of: Data(account.utf8)))

        try store.remove(account: account)
        XCTAssertNil(try store.data(account: account))
    }

    func testGoogleDestinationAndDefaultPolicyAreStableAcrossReconnect() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "First account",
            remoteRoot: "folder-1",
            configuration: configuration
        )
        let second = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Second account",
            remoteRoot: "folder-2",
            configuration: configuration
        )

        XCTAssertEqual(first, second)
        let policy = try XCTUnwrap(
            LibreReverseArchiveStore.policy(
                destinationID: first,
                configuration: configuration
            ))
        XCTAssertEqual(policy.coverageMode, .allHistory)
        XCTAssertNil(policy.coverageValue)
        XCTAssertTrue(policy.continuousArchive)
        XCTAssertEqual(
            policy.requiredLocalSeconds,
            LibreReverseArchivePolicy.defaultRequiredLocalSeconds
        )
        XCTAssertEqual(
            policy.rehydratedCacheBytes,
            LibreReverseArchivePolicy.defaultRehydratedCacheBytes
        )

        try LibreReverseArchiveStore.disableGoogleDriveDestination(configuration: configuration)
        XCTAssertNil(
            try LibreReverseArchiveStore.googleDriveDestination(configuration: configuration))
        let reconnected = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Third account",
            remoteRoot: "folder-3",
            configuration: configuration
        )
        XCTAssertEqual(reconnected, first)
        XCTAssertTrue(
            try XCTUnwrap(
                LibreReverseArchiveStore.googleDriveDestination(
                    configuration: configuration
                )
            ).enabled)
    }

    func testVerifiedRemoteVideosSelectOnlyTheSettledLocalDayInTimeOrder() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        let calendar = Calendar.autoupdatingCurrent
        let anchor = try XCTUnwrap(
            calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)
            ))
        let earlier = try makeVideo(
            at: anchor.addingTimeInterval(-3_600),
            path: "day-earlier.mp4",
            xid: "day-earlier",
            bytes: Data([1]),
            configuration: configuration
        )
        let later = try makeVideo(
            at: anchor.addingTimeInterval(3_600),
            path: "day-later.mp4",
            xid: "day-later",
            bytes: Data([2, 2]),
            configuration: configuration
        )
        _ = try makeVideo(
            at: anchor.addingTimeInterval(86_400),
            path: "next-day.mp4",
            xid: "next-day",
            bytes: Data([3, 3, 3]),
            configuration: configuration
        )
        try execute(
            "UPDATE archive_object SET remoteState='verified'",
            configuration
        )

        let interval = LibreReverseArchiveRehydrationPolicy.localDay(containing: anchor)
        XCTAssertEqual(
            try LibreReverseArchiveStore.verifiedRemoteVideos(
                in: interval,
                destinationID: destinationID,
                configuration: configuration
            ),
            [
                .init(
                    videoID: earlier,
                    relativePath: VideoStorage.relativePath(
                        xid: "day-earlier", date: anchor.addingTimeInterval(-3_600)
                    ),
                    byteCount: 1
                ),
                .init(
                    videoID: later,
                    relativePath: VideoStorage.relativePath(
                        xid: "day-later", date: anchor.addingTimeInterval(3_600)
                    ),
                    byteCount: 2
                ),
            ]
        )
    }

    func testFinalizedVideoEnqueuesAtomicallyForContinuousDestination() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )

        let videoID = try makeVideo(
            at: Date(),
            path: "continuous.mp4",
            xid: "continuous-xid",
            bytes: Data([1, 2, 3, 4]),
            configuration: configuration
        )
        let objects = try LibreReverseArchiveStore.objects(
            destinationID: destinationID,
            configuration: configuration
        )

        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].videoID, videoID)
        XCTAssertTrue(objects[0].relativePath.hasSuffix("/continuous-xid"))
        XCTAssertEqual(objects[0].byteCount, 4)
        XCTAssertEqual(objects[0].remoteState, .queued)
        XCTAssertTrue(objects[0].objectKey.hasPrefix("libraries/"))
        XCTAssertTrue(
            objects[0].objectKey.hasSuffix("/video/00000000000000000001/continuous-xid.mp4"))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency", configuration), 1)
    }

    func testReconciliationUsesFrameTimeAndIsIdempotent() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldID = try makeVideo(
            at: now.addingTimeInterval(-10 * 86_400),
            path: "old.mp4",
            xid: "old-xid",
            bytes: Data([0]),
            configuration: configuration
        )
        let recentID = try makeVideo(
            at: now.addingTimeInterval(-86_400),
            path: "recent.mp4",
            xid: "recent-xid",
            bytes: Data([1, 2]),
            configuration: configuration
        )
        let newestID = try makeVideo(
            at: now.addingTimeInterval(-3_600),
            path: "newest.mp4",
            xid: "newest-xid",
            bytes: Data([3, 4, 5]),
            configuration: configuration
        )
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        try LibreReverseArchiveStore.updatePolicy(
            .init(coverageMode: .lastDays, coverageValue: 2),
            destinationID: destinationID,
            configuration: configuration
        )

        let firstBatch = try LibreReverseArchiveStore.reconcileEligibleVideoBatch(
            destinationID: destinationID,
            limit: 1,
            now: now,
            configuration: configuration
        )
        XCTAssertEqual(firstBatch.insertedCount, 1)
        XCTAssertEqual(firstBatch.lastVideoID, oldID)
        let secondBatch = try LibreReverseArchiveStore.reconcileEligibleVideoBatch(
            destinationID: destinationID,
            afterVideoID: try XCTUnwrap(firstBatch.lastVideoID),
            limit: 1,
            now: now,
            configuration: configuration
        )
        XCTAssertEqual(secondBatch.insertedCount, 1)
        XCTAssertEqual(secondBatch.lastVideoID, recentID)
        let thirdBatch = try LibreReverseArchiveStore.reconcileEligibleVideoBatch(
            destinationID: destinationID,
            afterVideoID: try XCTUnwrap(secondBatch.lastVideoID),
            limit: 1,
            now: now,
            configuration: configuration
        )
        XCTAssertEqual(thirdBatch.insertedCount, 1)
        XCTAssertEqual(thirdBatch.lastVideoID, newestID)
        XCTAssertEqual(
            try LibreReverseArchiveStore.reconcileEligibleVideos(
                destinationID: destinationID,
                afterVideoID: newestID,
                now: now,
                configuration: configuration
            ), 0)
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).map(\.videoID),
            [oldID, recentID, newestID]
        )
    }

    func testCoverageIncludesAFileThatSpansTheCutoff() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try LibreReverseLibraryStore.admitFrame(
            createdAt: now.addingTimeInterval(-10 * 86_400),
            imageFileName: "spanning-old.png",
            context: nil,
            configuration: configuration
        )
        let recent = try LibreReverseLibraryStore.admitFrame(
            createdAt: now.addingTimeInterval(-86_400),
            imageFileName: "spanning-recent.png",
            context: nil,
            configuration: configuration
        )
        let spanningPath = VideoStorage.relativePath(
            xid: "spanning-xid", date: now.addingTimeInterval(-10 * 86_400)
        )
        let spanningURL = configuration.mediaRoot.appendingPathComponent(spanningPath)
        try FileManager.default.createDirectory(
            at: spanningURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: spanningURL)
        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: spanningPath,
                xid: "spanning-xid",
                width: 8,
                height: 8,
                frames: [
                    .init(frameID: old.id, videoFrameIndex: 0),
                    .init(frameID: recent.id, videoFrameIndex: 1),
                ]
            ),
            configuration: configuration
        )
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        try LibreReverseArchiveStore.updatePolicy(
            .init(coverageMode: .lastDays, coverageValue: 2),
            destinationID: destinationID,
            configuration: configuration
        )

        XCTAssertEqual(
            try LibreReverseArchiveStore.reconcileEligibleVideos(
                destinationID: destinationID,
                now: now,
                configuration: configuration
            ), 1)
        XCTAssertEqual(
            try LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first?.videoID, videoID)
    }

    func testContinuousFinalizationIncludesAFileThatSpansTheCutoff() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        let old = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date().addingTimeInterval(-40 * 86_400),
            imageFileName: "continuous-spanning-old.png",
            context: nil,
            configuration: configuration
        )
        let recent = try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(),
            imageFileName: "continuous-spanning-recent.png",
            context: nil,
            configuration: configuration
        )
        let spanningPath = VideoStorage.relativePath(
            xid: "continuous-spanning-xid", date: Date()
        )
        let spanningURL = configuration.mediaRoot.appendingPathComponent(spanningPath)
        try FileManager.default.createDirectory(
            at: spanningURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: spanningURL)
        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: spanningPath,
                xid: "continuous-spanning-xid",
                width: 8,
                height: 8,
                frames: [
                    .init(frameID: old.id, videoFrameIndex: 0),
                    .init(frameID: recent.id, videoFrameIndex: 1),
                ]
            ),
            configuration: configuration
        )

        let object = try XCTUnwrap(
            LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first(where: { $0.videoID == videoID }))
        XCTAssertEqual(object.remoteState, .queued)
    }

    func testArchivePolicyCannotDisableCompleteContinuousBackup() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let historicalID = try makeVideo(
            at: now.addingTimeInterval(-86_400),
            path: "historical.mp4",
            xid: "historical-xid",
            bytes: Data([1, 2, 3]),
            configuration: configuration
        )
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        try LibreReverseArchiveStore.updatePolicy(
            .init(
                coverageMode: .lastDays,
                coverageValue: 30,
                continuousArchive: false
            ),
            destinationID: destinationID,
            configuration: configuration
        )
        let normalized = try XCTUnwrap(
            LibreReverseArchiveStore.policy(
                destinationID: destinationID,
                configuration: configuration
            ))
        XCTAssertEqual(normalized.coverageMode, .allHistory)
        XCTAssertNil(normalized.coverageValue)
        XCTAssertTrue(normalized.continuousArchive)
        XCTAssertEqual(
            try LibreReverseArchiveStore.reconcileEligibleVideos(
                destinationID: destinationID,
                now: now,
                configuration: configuration
            ), 1)

        try LibreReverseArchiveStore.reconcilePolicyStates(
            destinationID: destinationID,
            now: now,
            configuration: configuration
        )
        let historicalObject = try XCTUnwrap(
            LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first(where: { $0.videoID == historicalID }))
        XCTAssertEqual(historicalObject.remoteState, .queued)

        let newlyFinalizedID = try makeVideo(
            at: now,
            path: "new.mp4",
            xid: "new-xid",
            bytes: Data([4, 5, 6]),
            configuration: configuration
        )
        let newObject = try XCTUnwrap(
            LibreReverseArchiveStore.objects(
                destinationID: destinationID,
                configuration: configuration
            ).first(where: { $0.videoID == newlyFinalizedID }))
        XCTAssertEqual(newObject.remoteState, .queued)
        let status = try LibreReverseArchiveStore.status(
            destinationID: destinationID,
            configuration: configuration
        )
        XCTAssertEqual(status.totalObjects, 2)
        XCTAssertEqual(status.queuedObjects, 2)
        XCTAssertEqual(status.historicalPendingObjects, 1)
        XCTAssertEqual(status.latestObjectState, .queued)
    }

    func testStrictPersistedEnumsAndPolicyValidationRejectUnknownValues() throws {
        XCTAssertThrowsError(try ArchiveRemoteState.decodePersisted("probably-fine")) {
            XCTAssertEqual(
                $0 as? LibreReverseArchiveStoreError,
                .invalidPersistedValue(type: "ArchiveRemoteState", value: "probably-fine")
            )
        }
        XCTAssertThrowsError(
            try LibreReverseArchivePolicy(
                coverageMode: .lastDays,
                coverageValue: -1
            ).coverageStart(now: Date()))
    }

    func testRetryBackoffIsDurableAndPreventsImmediateReclaim() throws {
        struct RetryableFailure: LocalizedError {
            var errorDescription: String? { "temporary outage" }
        }
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        _ = try makeVideo(
            at: Date(),
            path: "retry.mp4",
            xid: "retry-xid",
            bytes: Data([1, 2, 3]),
            configuration: configuration
        )
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let object = try XCTUnwrap(
            LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                now: failedAt,
                configuration: configuration
            ))
        try LibreReverseArchiveStore.recordObjectFailure(
            objectID: object.id,
            error: RetryableFailure(),
            retryable: true,
            now: failedAt,
            jitterSeconds: 0,
            configuration: configuration
        )

        XCTAssertNil(
            try LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                now: failedAt.addingTimeInterval(4.999),
                configuration: configuration
            ))
        let nextRetry = try XCTUnwrap(
            LibreReverseArchiveStore.nextRetryDate(
                destinationID: destinationID,
                configuration: configuration
            ))
        XCTAssertEqual(
            nextRetry.timeIntervalSince1970,
            failedAt.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertNotNil(
            try LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                now: failedAt.addingTimeInterval(5),
                configuration: configuration
            ))
    }

    func testExplicitRetryRequeuesTerminalFailure() throws {
        struct TerminalFailure: LocalizedError {
            var errorDescription: String? { "remote object is corrupt" }
        }
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        _ = try makeVideo(
            at: Date(),
            path: "terminal.mp4",
            xid: "terminal-xid",
            bytes: Data([1, 2, 3]),
            configuration: configuration
        )
        let claimed = try XCTUnwrap(
            LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                configuration: configuration
            ))
        try LibreReverseArchiveStore.recordObjectFailure(
            objectID: claimed.id,
            error: TerminalFailure(),
            retryable: false,
            configuration: configuration
        )
        XCTAssertNil(
            try LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                configuration: configuration
            ))

        try LibreReverseArchiveStore.retryFailedObjects(
            destinationID: destinationID,
            configuration: configuration
        )
        XCTAssertEqual(
            try LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                configuration: configuration
            )?.id, claimed.id)
    }

    func testAutomaticRetryWithoutResumableIdentifierStartsAFreshUpload() throws {
        struct RetryableFailure: LocalizedError {
            var errorDescription: String? { "provider unavailable before upload session" }
        }
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        _ = try makeVideo(
            at: Date(),
            path: "retry-before-session.mp4",
            xid: "retry-before-session-xid",
            bytes: Data([1, 2, 3]),
            configuration: configuration
        )
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstClaim = try XCTUnwrap(
            LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                now: failedAt,
                configuration: configuration
            ))
        try LibreReverseArchiveStore.recordObjectFailure(
            objectID: firstClaim.id,
            error: RetryableFailure(),
            retryable: true,
            now: failedAt,
            jitterSeconds: 0,
            configuration: configuration
        )

        let retry = try XCTUnwrap(
            LibreReverseArchiveStore.claimNextQueuedObject(
                destinationID: destinationID,
                now: failedAt.addingTimeInterval(5),
                configuration: configuration
            ))
        try LibreReverseArchiveStore.recordHashedObject(
            objectID: retry.id,
            integrity: .init(byteCount: 3, sha256: String(repeating: "a", count: 64)),
            configuration: configuration
        )
        let key = ArchiveObjectKey(retry.objectKey)
        XCTAssertNil(
            try LibreReverseArchiveStore.uploadCheckpoint(
                objectID: retry.id,
                key: key,
                configuration: configuration
            ))

        let fresh = ArchiveUploadSession(
            identifier: "fresh-resumable-session",
            key: key,
            totalBytes: 3
        )
        try LibreReverseArchiveStore.checkpointUpload(
            objectID: retry.id,
            session: fresh,
            configuration: configuration
        )
        XCTAssertEqual(
            try LibreReverseArchiveStore.uploadCheckpoint(
                objectID: retry.id,
                key: key,
                configuration: configuration
            ), fresh)
    }

    func testResidencyForecastSurfacesBytesThatCannotYetBeFreedSafely() throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationID = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "Drive",
            remoteRoot: "folder",
            configuration: configuration
        )
        _ = try makeVideo(
            at: Date(),
            path: "not-uploaded.mp4",
            xid: "not-uploaded-xid",
            bytes: Data([1, 2, 3]),
            configuration: configuration
        )
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
            ),
            .init(
                bytesSelectedForRemoval: 3,
                bytesSafelyEvictable: 0,
                bytesWaitingForVerification: 3
            )
        )
    }

    private func makeVideo(
        at date: Date,
        path _: String,
        xid: String,
        bytes: Data,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        let admitted = try LibreReverseLibraryStore.admitFrame(
            createdAt: date,
            imageFileName: "\(xid).png",
            context: nil,
            configuration: configuration
        )
        let path = VideoStorage.relativePath(xid: xid, date: date)
        let mediaURL = configuration.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: mediaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: mediaURL)
        return try LibreReverseLibraryStore.commitRecordedChunk(
            .init(
                relativeMediaPath: path,
                xid: xid,
                width: 8,
                height: 8,
                frames: [.init(frameID: admitted.id, videoFrameIndex: 0)]
            ),
            configuration: configuration
        )
    }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-archive-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    private func scalar(
        _ sql: String,
        _ configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(configuration.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK)
        let value = try XCTUnwrap(database)
        defer { sqlite3_close(value) }
        XCTAssertEqual(
            key.withUnsafeBytes { sqlite3_key(value, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(value, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        return sqlite3_column_int64(query, 0)
    }

    private func execute(
        _ sql: String,
        _ configuration: LibreReverseLibraryConfiguration
    ) throws {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(configuration.databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK)
        let value = try XCTUnwrap(database)
        defer { sqlite3_close(value) }
        XCTAssertEqual(
            key.withUnsafeBytes { sqlite3_key(value, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(value, sql, nil, nil, nil), SQLITE_OK)
    }
}
#endif
