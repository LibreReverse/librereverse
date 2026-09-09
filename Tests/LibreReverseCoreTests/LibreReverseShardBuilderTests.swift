#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibreReverseShardBuilderTests: XCTestCase {
    func testRolloverFailureRetryCadenceAvoidsRapidCorruptQueueChunking() {
        XCTAssertEqual(
            LibreReverseShardRolloverError.pendingMeetingTranscriptions(["meeting"])
                .retryDelay,
            15 * 60
        )
        XCTAssertEqual(
            LibreReverseShardRolloverError.unresolvedMeetingTranscriptionJobs(["orphan.json"])
                .retryDelay,
            60 * 60
        )
        XCTAssertEqual(
            LibreReverseShardRolloverError.replacementValidationFailed.retryDelay,
            15 * 60
        )
    }

    func testRestartableBuilderCopiesEachOwnedPayloadAndPreservesIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-builder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        try execute(
            source,
            """
            INSERT INTO segment(id,bundleID,startDate,endDate,type)
            VALUES(10,'com.example.Editor','2025-02-19T01:00:00.000','2025-02-19T02:00:00.000',0),
                  (11,'com.example.Later','2025-03-21T01:00:00.000','2025-03-21T02:00:00.000',0);
            INSERT INTO video(id,height,width,path,fileSize,frameRate,xid)
            VALUES(20,100,200,'202502/19/video-xid',3,30,'video-xid');
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus)
            VALUES(100,'2025-02-19T01:00:00.000','100.png',10,20,0,1,'success'),
                  (101,'2025-02-20T01:00:00.000','101.png',10,20,1,0,'success'),
                  (102,'2025-03-21T01:00:00.000','102.png',11,NULL,NULL,0,'deferred'),
                  (103,'2025-03-21T00:00:00.000', 'boundary.png',11,NULL,NULL,0,'deferred');
            INSERT INTO node(id,frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height)
            VALUES(1000,100,0,0,5,1,2,3,4),(1001,101,0,0,6,1,2,3,4),
                  (1002,102,0,0,7,1,2,3,4);
            INSERT INTO searchRanking(rowid,text,otherText,title)
            VALUES(500,'first text','','First'),(501,'null frame text','','Null'),
                  (502,'outside','','Outside');
            INSERT INTO search(rowid,text,otherText)
            VALUES(500,'first text',''),(501,'null frame text',''),(502,'outside','');
            INSERT INTO searchOffsets(rowid,text,otherText)
            VALUES(500,'first text',''),(501,'null frame text',''),(502,'outside','');
            INSERT INTO doc_segment(docid,segmentId,frameId)
            VALUES(500,10,100),(501,10,NULL),(502,11,102);
            INSERT INTO audio(id,segmentId,path,startTime,duration)
            VALUES(600,10,'audio.m4a','2025-02-19T01:00:00.000',10);
            INSERT INTO transcript_word(id,segmentId,speechSource,word,timeOffset,duration)
            VALUES(700,10,'microphone','hello',0,100);
            """)

        let epoch = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2025-02-19T00:00:00Z"
            ))
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))' WHERE id=1
            """)
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let destination = root.appendingPathComponent("Library/Shards/\(interval.fileName)")
        try LibreReverseShardBuilder.prepare(
            source: source,
            destinationURL: destination,
            interval: interval
        )

        // One-row batches force durable restart checkpoints through both frame
        // and node phases rather than succeeding in one opaque transaction.
        var observed: [LibreReverseShardBuildProgress.Phase] = []
        let manifest = try LibreReverseShardBuilder.buildToCompletion(
            source: source,
            destinationURL: destination,
            interval: interval,
            batchSize: 1
        ) { observed.append($0.phase) }

        XCTAssertTrue(observed.contains(.frames))
        XCTAssertTrue(observed.contains(.nodes))
        XCTAssertTrue(observed.contains(.search))
        XCTAssertEqual(manifest.frameCount, 2)
        XCTAssertEqual(manifest.nodeCount, 2)
        XCTAssertEqual(manifest.documentCount, 2)
        XCTAssertEqual(manifest.minFrameID, 100)
        XCTAssertEqual(manifest.maxFrameID, 101)
        XCTAssertGreaterThan(manifest.byteCount, 0)
        XCTAssertEqual(try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM frame"), 2)
        XCTAssertEqual(try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM node"), 2)
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM searchRanking"), 2)
        XCTAssertEqual(try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM search"), 2)
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM searchOffsets"), 2)
        XCTAssertEqual(try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM audio"), 1)
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM transcript_word"), 1)
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM frame WHERE id=102"), 0
        )
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM frame WHERE id=103"), 0
        )
        XCTAssertEqual(
            try scalar(destination, source.keyFileURL, "SELECT COUNT(*) FROM node WHERE id=1002"), 0
        )

        // A completed build can be reopened and sealed again without copying
        // or changing its checksum.
        let repeated = try LibreReverseShardBuilder.seal(
            source: source,
            destinationURL: destination,
            interval: interval
        )
        XCTAssertEqual(repeated, manifest)

        let activeInterval = LibreReverseShardInterval(ordinal: 1, epochStart: epoch)
        let replacementURL = root.appendingPathComponent("Library/replacement.sqlite3")
        let savedDownload = LibreReverseDownloadRequest(date: epoch, shardOrdinal: 0)
        try LibreReverseDownloadRequestStore(library: source).save(savedDownload)
        let primary = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: source,
            destinationURL: replacementURL,
            activeInterval: activeInterval,
            sealedShards: [
                .init(
                    manifest: manifest,
                    relativePath: "Shards/\(interval.fileName)"
                )
            ]
        )
        XCTAssertEqual(try scalar(replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM archive_download_request"), 1)
        XCTAssertEqual(primary.activeFrameCount, 2)
        XCTAssertEqual(primary.activeNodeCount, 1)
        XCTAssertEqual(primary.activeDocumentCount, 1)
        XCTAssertEqual(
            try scalar(replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM segment"), 2)
        XCTAssertEqual(
            try scalar(replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM library_shard"), 1)
        XCTAssertEqual(
            try scalar(replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM shard_star"), 1)
        XCTAssertEqual(
            try scalar(
                replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM frame WHERE id=103"), 1)

        let session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacementURL,
                keyFileURL: source.keyFileURL,
                mediaRoot: source.mediaRoot
            ))
        let historical = try await session.nearestMoment(to: epoch.addingTimeInterval(3_600))
        XCTAssertEqual(historical?.wallDate, epoch.addingTimeInterval(3_600))
        let boundary = try await session.nearestMoment(to: activeInterval.start)
        XCTAssertEqual(boundary?.wallDate, activeInterval.start)
        await session.closeConnection()

        // The next exact boundary seals only the formerly writable interval,
        // preserves existing shard IDs/provider metadata, and atomically
        // replaces the primary with an empty new writable interval.
        let replacementConfiguration = LibreReverseLibraryConfiguration(
            databaseURL: replacementURL,
            keyFileURL: source.keyFileURL,
            mediaRoot: source.mediaRoot
        )
        let originalStarDate = epoch.addingTimeInterval(3_600)
        let addedStarDate = epoch.addingTimeInterval(86_400 + 3_600)
        let removed = try LibreReverseLibraryStore.setFrameStarred(
            frameID: 100,
            wallDate: originalStarDate,
            isStarred: false,
            configuration: replacementConfiguration
        )
        guard case .shard(let starShardID, .sealedLocal) = removed.owner else {
            return XCTFail("sealed history must mutate the compact shard-star catalog")
        }
        XCTAssertFalse(removed.isStarred)
        XCTAssertEqual(
            try scalar(
                replacementURL,
                source.keyFileURL,
                "SELECT COUNT(*) FROM shard_star WHERE frameId=100"
            ),
            0
        )
        try execute(
            replacementConfiguration,
            "UPDATE library_shard SET state='remote_only' WHERE id=\(starShardID)"
        )
        let added = try LibreReverseLibraryStore.setFrameStarred(
            frameID: 101,
            wallDate: addedStarDate,
            isStarred: true,
            configuration: replacementConfiguration
        )
        XCTAssertEqual(added.owner, .shard(id: starShardID, state: .remoteOnly))
        let starSession = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacementURL,
                keyFileURL: source.keyFileURL,
                mediaRoot: source.mediaRoot
            )
        )
        let starredDates = try await starSession.starredFrameDates()
        XCTAssertEqual(starredDates, [addedStarDate])
        await starSession.closeConnection()
        try execute(
            replacementConfiguration,
            "UPDATE library_shard SET state='sealed_local' WHERE id=\(starShardID)"
        )
        let searchSession = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacementURL,
                keyFileURL: source.keyFileURL,
                mediaRoot: source.mediaRoot
            )
        )
        let starredFacet = SearchFacets(isStarred: true)
        let removedStarResults = try await searchSession.recencySearchCandidates(
            query: "first",
            facets: starredFacet
        )
        XCTAssertTrue(removedStarResults.isEmpty)
        _ = try LibreReverseLibraryStore.setFrameStarred(
            frameID: 100,
            wallDate: originalStarDate,
            isStarred: true,
            configuration: replacementConfiguration
        )
        let restoredStarResults = try await searchSession.recencySearchCandidates(
            query: "first",
            facets: starredFacet
        )
        XCTAssertEqual(restoredStarResults.map(\.frameID), [100])
        XCTAssertEqual(restoredStarResults.map(\.isStarred), [true])
        await searchSession.closeConnection()

        let existingShardID = try scalar(
            replacementURL, source.keyFileURL,
            "SELECT id FROM library_shard WHERE ordinal=0"
        )
        try execute(
            replacementConfiguration,
            """
            UPDATE library_shard SET remoteIdentifier='remote-existing',
              remoteVersion='v1',remoteSHA256=sha256,
              verifiedAt='2025-04-01T00:00:00.000' WHERE id=\(existingShardID)
            """)
        try execute(replacementConfiguration, """
            INSERT INTO shard_archive_retired_object(
              id,shardId,destinationId,objectKey,remoteIdentifier,remoteVersion,remoteSHA256,
              byteCount,retiredAt,deleteState,attempt,retryAfter,lastError
            ) VALUES(71,\(existingShardID),19,'old-key','old-remote','v3','old-sha',456,
              '2025-04-01','retry_wait',2,'2025-04-02','retryable');
            """)
        let rollover = try XCTUnwrap(
            LibreReverseShardRollover.performIfNeeded(
                at: activeInterval.end,
                configuration: replacementConfiguration,
                batchSize: 1
            ))
        XCTAssertEqual(try scalar(replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM archive_download_request"), 1,
                       "Pending downloads must survive primary compaction and rollover")
        XCTAssertEqual(try scalar(replacementURL, source.keyFileURL, """
            SELECT COUNT(*) FROM shard_archive_retired_object WHERE id=71 AND shardId=\(existingShardID)
              AND destinationId=19 AND objectKey='old-key' AND remoteIdentifier='old-remote'
              AND remoteVersion='v3' AND remoteSHA256='old-sha' AND byteCount=456
              AND deleteState='retry_wait' AND attempt=2 AND retryAfter='2025-04-02'
              AND lastError='retryable'
            """), 1)
        XCTAssertEqual(rollover.previousActiveOrdinal, 1)
        XCTAssertEqual(rollover.activeOrdinal, 2)
        XCTAssertEqual(rollover.sealedShards.map(\.frameCount), [2])
        XCTAssertEqual(
            try scalar(
                replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM frame"
            ), 0)
        XCTAssertEqual(
            try scalar(
                replacementURL, source.keyFileURL, "SELECT COUNT(*) FROM library_shard"
            ), 2)
        XCTAssertEqual(
            try scalar(
                replacementURL, source.keyFileURL,
                "SELECT id FROM library_shard WHERE ordinal=0"
            ), existingShardID)
        XCTAssertEqual(
            try scalar(
                replacementURL, source.keyFileURL,
                "SELECT COUNT(*) FROM library_shard WHERE id=\(existingShardID) AND remoteIdentifier='remote-existing'"
            ), 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: replacementURL.deletingLastPathComponent()
                    .appendingPathComponent("library.sqlite3.rollover").path
            ))

        let rolledSession = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: replacementURL,
                keyFileURL: source.keyFileURL,
                mediaRoot: source.mediaRoot
            ))
        let rolledHistorical = try await rolledSession.nearestMoment(
            to: activeInterval.start
        )
        XCTAssertEqual(rolledHistorical?.wallDate, activeInterval.start)
        await rolledSession.closeConnection()
    }

    func testBuilderRejectsSourceMutationAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-source-change-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let destination = root.appendingPathComponent("Library/Shards/building.sqlite3")
        try LibreReverseShardBuilder.prepare(
            source: source,
            destinationURL: destination,
            interval: interval
        )
        try execute(
            source,
            """
            INSERT INTO frame(id,createdAt,imageFileName,isStarred,encodingStatus)
            VALUES(99,'\(databaseString(epoch))','late.png',0,'deferred')
            """)
        XCTAssertThrowsError(
            try LibreReverseShardBuilder.advance(
                source: source,
                destinationURL: destination,
                interval: interval
            )
        ) { error in
            XCTAssertEqual(error as? LibreReverseShardBuilderError, .sourceChanged)
        }
    }

    func testRolloverDefersBeforeStrandingPendingMeetingTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-transcript-barrier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Date(timeIntervalSince1970: 1_740_528_000)
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))',activeOrdinal=0 WHERE id=1
            """)
        let startedAt = epoch.addingTimeInterval(3_600)
        let xid = "rollover-pending-meeting"
        let path = VideoStorage.relativePath(xid: xid, date: startedAt)
        try insertMeeting(
            configuration: source,
            segmentID: 10,
            videoID: 20,
            frameID: 30,
            audioID: 40,
            xid: xid,
            path: path,
            startedAt: startedAt
        )
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("Library/MeetingTranscriptionQueue")
        )
        try queue.enqueue(
            .init(
                publicationXID: xid,
                segmentID: 10,
                videoID: 20,
                title: "Pending meeting",
                relativeMediaPath: path,
                createdAt: startedAt
            ))

        XCTAssertThrowsError(
            try LibreReverseShardRollover.performIfNeeded(
                at: epoch.addingTimeInterval(LibreReverseShardInterval.duration),
                configuration: source,
                transcriptionQueue: queue
            )
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseShardRolloverError,
                .pendingMeetingTranscriptions([xid])
            )
        }
        XCTAssertEqual(
            try LibreReverseShardStore.activeOrdinal(configuration: source),
            0
        )
        XCTAssertNotNil(
            try LibreReverseLibraryStore.publishedMeeting(
                xid: xid,
                configuration: source
            ))
    }

    func testRolloverDefersBeforeStrandingRecoverableSparseFrame() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-frame-barrier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Date(timeIntervalSince1970: 1_740_528_000)
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))',activeOrdinal=0 WHERE id=1
            """)
        _ = try LibreReverseLibraryStore.admitFrame(
            createdAt: epoch.addingTimeInterval(3_600),
            imageFileName: "recoverable.png",
            context: .init(bundleID: "com.example.Editor", windowName: nil),
            captureSessionID: "interrupted-session",
            configuration: source
        )

        XCTAssertThrowsError(
            try LibreReverseShardRollover.performIfNeeded(
                at: epoch.addingTimeInterval(LibreReverseShardInterval.duration),
                configuration: source
            )
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseShardRolloverError,
                .pendingSparseFrameRecovery(1)
            )
        }
        XCTAssertEqual(
            try LibreReverseShardStore.activeOrdinal(configuration: source),
            0
        )
        XCTAssertEqual(
            try LibreReverseLibraryStore.loadRecoverableFrames(configuration: source).count,
            1
        )
    }

    func testRolloverRetainsRecoverableSparseFrameInReplacementInterval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-current-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Date(timeIntervalSince1970: 1_740_528_000)
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))',activeOrdinal=0 WHERE id=1
            """)
        let targetStart = epoch.addingTimeInterval(LibreReverseShardInterval.duration)
        _ = try LibreReverseLibraryStore.admitFrame(
            createdAt: targetStart.addingTimeInterval(3_600),
            imageFileName: "current-recoverable.png",
            context: .init(bundleID: "com.example.Editor", windowName: nil),
            captureSessionID: "current-session",
            configuration: source
        )

        let result = try XCTUnwrap(
            LibreReverseShardRollover.performIfNeeded(
                at: targetStart.addingTimeInterval(3_600),
                configuration: source
            ))
        XCTAssertEqual(result.activeOrdinal, 1)
        XCTAssertEqual(
            try LibreReverseLibraryStore.loadRecoverableFrames(configuration: source).count,
            1
        )
    }

    func testRolloverAllowsPendingTranscriptOwnedByReplacementInterval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-current-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Date(timeIntervalSince1970: 1_740_528_000)
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))',activeOrdinal=0 WHERE id=1
            """)
        let targetStart = epoch.addingTimeInterval(LibreReverseShardInterval.duration)
        let startedAt = targetStart.addingTimeInterval(3_600)
        let xid = "rollover-current-meeting"
        let path = VideoStorage.relativePath(xid: xid, date: startedAt)
        try insertMeeting(
            configuration: source,
            segmentID: 11,
            videoID: 21,
            frameID: 31,
            audioID: 41,
            xid: xid,
            path: path,
            startedAt: startedAt
        )
        let queue = LibreReverseMeetingTranscriptionQueue(
            root: root.appendingPathComponent("Library/MeetingTranscriptionQueue")
        )
        try queue.enqueue(
            .init(
                publicationXID: xid,
                segmentID: 11,
                videoID: 21,
                title: "Current meeting",
                relativeMediaPath: path,
                createdAt: startedAt
            ))

        let result = try XCTUnwrap(
            LibreReverseShardRollover.performIfNeeded(
                at: startedAt,
                configuration: source,
                transcriptionQueue: queue
            ))
        XCTAssertEqual(result.activeOrdinal, 1)
        XCTAssertNotNil(
            try LibreReverseLibraryStore.publishedMeeting(
                xid: xid,
                configuration: source
            ))
        XCTAssertEqual(try queue.pending().map(\.publicationXID), [xid])
    }

    func testRolloverFailsClosedForUnresolvedTranscriptionQueueFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-shard-corrupt-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media")
        )
        try LibreReverseLibraryStore.initialize(source)
        let epoch = Date(timeIntervalSince1970: 1_740_528_000)
        try execute(
            source,
            """
            UPDATE shard_metadata
               SET epochStart='\(databaseString(epoch))',activeOrdinal=0 WHERE id=1
            """)
        let queueRoot = root.appendingPathComponent("Library/MeetingTranscriptionQueue")
        try FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: queueRoot.appendingPathComponent("orphan.json")
        )
        let queue = LibreReverseMeetingTranscriptionQueue(root: queueRoot)

        XCTAssertThrowsError(
            try LibreReverseShardRollover.performIfNeeded(
                at: epoch.addingTimeInterval(LibreReverseShardInterval.duration),
                configuration: source,
                transcriptionQueue: queue
            )
        ) { error in
            XCTAssertEqual(
                error as? LibreReverseShardRolloverError,
                .unresolvedMeetingTranscriptionJobs(["orphan.json"])
            )
        }
        XCTAssertEqual(
            try LibreReverseShardStore.activeOrdinal(configuration: source),
            0
        )
    }

    private func insertMeeting(
        configuration: LibreReverseLibraryConfiguration,
        segmentID: Int64,
        videoID: Int64,
        frameID: Int64,
        audioID: Int64,
        xid: String,
        path: String,
        startedAt: Date
    ) throws {
        let started = databaseString(startedAt)
        let ended = databaseString(startedAt.addingTimeInterval(600))
        try execute(
            configuration,
            """
            INSERT INTO segment(id,bundleID,startDate,endDate,type,windowName)
            VALUES(\(segmentID),'us.zoom.xos','\(started)','\(ended)',1,'Meeting');
            INSERT INTO video(id,height,width,path,fileSize,frameRate,xid)
            VALUES(\(videoID),1080,1920,'\(path)',1,30,'\(xid)');
            INSERT INTO frame(
              id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus
            ) VALUES(\(frameID),'\(started)','\(frameID).png',\(segmentID),\(videoID),0,0,'success');
            INSERT INTO audio(id,segmentId,path,startTime,duration)
            VALUES(\(audioID),\(segmentID),'\(path)','\(started)',600);
            """)
    }

    private func execute(_ configuration: LibreReverseLibraryConfiguration, _ sql: String) throws {
        try withDatabase(configuration.databaseURL, configuration.keyFileURL) { database in
            var message: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(database, sql, nil, nil, &message)
            guard status == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "sqlite error"
                sqlite3_free(message)
                throw NSError(
                    domain: "ShardBuilderTests", code: Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey: text
                    ])
            }
        }
    }

    private func scalar(_ url: URL, _ keyURL: URL, _ sql: String) throws -> Int64 {
        try withDatabase(url, keyURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else { throw NSError(domain: "ShardBuilderTests", code: 1) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw NSError(domain: "ShardBuilderTests", code: 2)
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func withDatabase<T>(
        _ url: URL,
        _ keyURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let key = try Data(contentsOf: keyURL)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let database
        else { throw NSError(domain: "ShardBuilderTests", code: 3) }
        defer { sqlite3_close(database) }
        let status = key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }
        guard status == SQLITE_OK else { throw NSError(domain: "ShardBuilderTests", code: 4) }
        return try operation(database)
    }

    private func databaseString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

}
#endif
