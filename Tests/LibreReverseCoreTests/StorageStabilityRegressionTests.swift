#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

/// Synthetic regressions for the storage stability audit.
final class StorageStabilityRegressionTests: XCTestCase {
    func testReadingPendingTitleUpdatesPreservesLiveLeaseAndBlocksEviction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = try LibreReverseArchiveStore.upsertGoogleDriveDestination(
            displayName: "synthetic", remoteRoot: "synthetic", configuration: fixture.library)
        _ = try LibreReverseArchiveStore.reconcileEligibleVideos(
            destinationID: destination, configuration: fixture.library)
        try execute("UPDATE media_residency SET desiredLocal=0", fixture.library)
        try execute("UPDATE archive_object SET remoteState='verified',localSHA256='abc',remoteSHA256='abc',remoteIdentifier='synthetic'", fixture.library)
        let candidate = try XCTUnwrap(LibreReverseArchiveStore.evictionCandidates(
            destinationID: destination, configuration: fixture.library).first)
        let lease = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
        defer { lease.release() }
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        XCTAssertFalse(try LibreReverseArchiveStore.stageEviction(
            candidate: candidate, stagingPath: "synthetic-staged", destinationID: destination,
            configuration: fixture.library))
        XCTAssertTrue(try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: fixture.library).isEmpty)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        XCTAssertFalse(try LibreReverseArchiveStore.stageEviction(
            candidate: candidate, stagingPath: "synthetic-staged", destinationID: destination,
            configuration: fixture.library))
        withExtendedLifetime(lease) {}
    }

    func testReadingPendingTitleUpdatesPreservesOngoingDownload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try LibreReverseArchiveStore.beginRehydration(videoID: fixture.videoID, configuration: fixture.library)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency WHERE localState='downloading'", fixture.library), 1)
        _ = try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: fixture.library)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency WHERE localState='downloading'", fixture.library), 1)
        XCTAssertNoThrow(try LibreReverseArchiveStore.markRehydrationInstalling(
            videoID: fixture.videoID, configuration: fixture.library))
    }

    func testReleasingOldLeasePreservesAnotherReadersLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
        _ = try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: fixture.library)
        let second = try LibreReverseMediaLease(videoID: fixture.videoID, library: fixture.library)
        defer { second.release() }
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 2)
        first.release()
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 1)
        withExtendedLifetime(second) {}
    }

    func testPrimaryReplacementPreservesPendingOCRAndProtectsUnindexedImage() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = try LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library)
        XCTAssertEqual(pending.count, 1)
        let frameID = try XCTUnwrap(pending.first?.id)
        XCTAssertFalse(try LibreReverseLibraryStore.canRemoveSourceImage(frameID: frameID, configuration: fixture.library))
        let epoch = try LibreReverseShardStore.epochStart(configuration: fixture.library)
        let active = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let replacementURL = fixture.root.appendingPathComponent("replacement.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: fixture.library, destinationURL: replacementURL,
            activeInterval: active, sealedShards: [])
        let replacement = LibreReverseLibraryConfiguration(databaseURL: replacementURL,
            keyFileURL: fixture.library.keyFileURL, mediaRoot: fixture.library.mediaRoot)
        // Retained frames must retain durable OCR work until publication.
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame", replacement), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment", replacement), 0)
        XCTAssertEqual(try LibreReverseLibraryStore.pendingOCRFrames(configuration: replacement).map(\.id), [frameID])
        XCTAssertFalse(try LibreReverseLibraryStore.canRemoveSourceImage(frameID: frameID, configuration: replacement))
    }

    func testRolloverPreservesGlobalIDsAndBothHistoricalSearchResults() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldFrame = try XCTUnwrap(LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library).first)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: oldFrame.id,
            document: .init(text: "auditcollision historical", otherText: "", nodes: []), configuration: fixture.library)
        let generatedID = try scalar("SELECT docid FROM doc_segment", fixture.library)
        try execute("""
            INSERT INTO searchRanking(rowid,text,otherText,title) SELECT 777,text,otherText,title FROM searchRanking WHERE rowid=\(generatedID);
            INSERT INTO search(rowid,text,otherText) SELECT 777,text,otherText FROM search WHERE rowid=\(generatedID);
            INSERT INTO searchOffsets(rowid,text,otherText) SELECT 777,text,otherText FROM searchOffsets WHERE rowid=\(generatedID);
            DELETE FROM searchRanking WHERE rowid=\(generatedID);
            DELETE FROM search WHERE rowid=\(generatedID);
            DELETE FROM searchOffsets WHERE rowid=\(generatedID);
            UPDATE doc_segment SET docid=777 WHERE docid=\(generatedID);
            DELETE FROM document_id_sequence;
            """, fixture.library)
        let oldDocID = try scalar("SELECT docid FROM doc_segment", fixture.library)
        let epoch = try LibreReverseShardStore.epochStart(configuration: fixture.library)
        let oldInterval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let shardURL = fixture.root.appendingPathComponent("Shards/" + oldInterval.fileName)
        let manifest = try LibreReverseShardBuilder.buildToCompletion(source: fixture.library,
            destinationURL: shardURL, interval: oldInterval, batchSize: 1)
        let active = LibreReverseShardInterval(ordinal: 1, epochStart: epoch)
        let replacementURL = fixture.root.appendingPathComponent("replacement.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: fixture.library,
            destinationURL: replacementURL, activeInterval: active,
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/" + oldInterval.fileName)])
        let replacement = LibreReverseLibraryConfiguration(databaseURL: replacementURL,
            keyFileURL: fixture.library.keyFileURL, mediaRoot: fixture.library.mediaRoot)
        let date = active.start.addingTimeInterval(60)
        let newFrame = try LibreReverseLibraryStore.admitFrame(createdAt: date,
            imageFileName: "new.png", context: nil, configuration: replacement)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: newFrame.id,
            document: .init(text: "auditcollision current", otherText: "", nodes: []), configuration: replacement)
        let newDocID = try scalar("SELECT docid FROM doc_segment", replacement)
        XCTAssertGreaterThan(newFrame.id, oldFrame.id)
        XCTAssertNotEqual(newDocID, oldDocID)
        XCTAssertLessThan(newDocID, 0)
        let path = VideoStorage.relativePath(xid: "new-frame", date: date)
        let url = replacement.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: url)
        _ = try LibreReverseLibraryStore.commitRecordedChunk(.init(relativeMediaPath: path,
            xid: "new-frame", width: 8, height: 8,
            frames: [.init(frameID: newFrame.id, videoFrameIndex: 0)]), configuration: replacement)
        let reader = LibraryDatabaseSession(configuration: .init(databaseURL: replacement.databaseURL,
            keyFileURL: replacement.keyFileURL, mediaRoot: replacement.mediaRoot))
        let results = try await reader.recencySearchCandidates(query: "auditcollision")
        await reader.closeConnection()
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.frameDate, date)
        // A second real rollover seals negative documents and must retain
        // their allocator watermark even though the new primary is empty.
        _ = try XCTUnwrap(LibreReverseShardRollover.performIfNeeded(at: active.end, configuration: replacement, batchSize: 1))
        let third = try LibreReverseLibraryStore.admitFrame(createdAt: active.end.addingTimeInterval(60),
            imageFileName: "third.png", context: nil, configuration: replacement)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: third.id,
            document: .init(text: "auditcollision third", otherText: "", nodes: []), configuration: replacement)
        XCTAssertGreaterThan(third.id, newFrame.id)
        let thirdDocID = try scalar("SELECT docid FROM doc_segment", replacement)
        XCTAssertLessThan(thirdDocID, newDocID)
        let negativeShardReader = LibraryDatabaseSession(configuration: .init(databaseURL: replacement.databaseURL,
            keyFileURL: replacement.keyFileURL, mediaRoot: replacement.mediaRoot))
        let three = try await negativeShardReader.recencySearchCandidates(query: "auditcollision")
        await negativeShardReader.closeConnection()
        XCTAssertEqual(Set(three.map(\.docID)), Set([oldDocID, newDocID, thirdDocID]))
    }

    func testSealingRejectsEncodedFramesWithPendingOCR() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let epoch = try LibreReverseShardStore.epochStart(configuration: fixture.library)
        let interval = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let target = fixture.root.appendingPathComponent("Shards/" + interval.fileName)
        XCTAssertThrowsError(try LibreReverseShardBuilder.buildToCompletion(source: fixture.library,
            destinationURL: target, interval: interval)) { error in
            XCTAssertEqual(error as? LibreReverseShardBuilderError, .pendingOCRFrames(1))
        }
        XCTAssertEqual(try LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library).count, 1)
    }

    func testOnlyExplicitStartupRecoveryClearsInterruptedOwnership() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute("UPDATE media_residency SET activeLeases=2,localState='installing'", fixture.library)
        try LibreReverseArchiveStore.initialize(fixture.library)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency WHERE localState='installing'", fixture.library), 1)
        try LibreReverseArchiveStore.recoverInterruptedResidency(configuration: fixture.library)
        XCTAssertEqual(try scalar("SELECT activeLeases FROM media_residency", fixture.library), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM media_residency WHERE localState='absent'", fixture.library), 1)
    }

    func testLegacyRemoteShardFrameMaximumRepairsFutureAllocationWithoutDownloading() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute("""
            INSERT INTO library_shard(ordinal,generation,relativePath,state,schemaVersion,keyVersion,
              frameCount,minFrameId,maxFrameId) VALUES(-1,1,'Shards/remote.sqlite3','remote_only',41,1,1,10000,10000);
            """, fixture.library)
        try LibreReverseLibraryStore.initialize(fixture.library)
        let frame = try LibreReverseLibraryStore.admitFrame(createdAt: Date(), imageFileName: "new.png",
            context: nil, configuration: fixture.library)
        XCTAssertGreaterThan(frame.id, 10000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Shards/remote.sqlite3").path))
    }

    func testDeletingArchivedMeetingPreservesBothKindsOfStarOverlay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try XCTUnwrap(LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library).first)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: first.id,
            document: .init(text: "first", otherText: "", nodes: []), configuration: fixture.library)
        let secondDate = fixture.date.addingTimeInterval(1)
        let second = try LibreReverseLibraryStore.admitFrame(createdAt: secondDate, imageFileName: "second.png",
            context: nil, isStarred: true, configuration: fixture.library)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: second.id,
            document: .init(text: "second", otherText: "", nodes: []), configuration: fixture.library)
        let secondPath = try writeMedia(xid: "second", date: secondDate, library: fixture.library)
        _ = try LibreReverseLibraryStore.commitRecordedChunk(.init(relativeMediaPath: secondPath, xid: "second",
            width: 8, height: 8, frames: [.init(frameID: second.id, videoFrameIndex: 0)]), configuration: fixture.library)
        let meetingDate = fixture.date.addingTimeInterval(2)
        let meetingPath = try writeMedia(xid: "meeting", date: meetingDate, library: fixture.library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(.init(startDate: meetingDate,
            endDate: meetingDate.addingTimeInterval(60), relativeMediaPath: meetingPath, xid: "meeting",
            width: 8, height: 8, frameRate: 30, audioStartTime: meetingDate, duration: 60), configuration: fixture.library)
        let epoch = try LibreReverseShardStore.epochStart(configuration: fixture.library)
        let closed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let manifest = try LibreReverseShardBuilder.buildToCompletion(source: fixture.library,
            destinationURL: fixture.root.appendingPathComponent("Shards/" + closed.fileName), interval: closed, batchSize: 1)
        let url = fixture.root.appendingPathComponent("replacement.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: fixture.library, destinationURL: url,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: "Shards/" + closed.fileName)])
        let library = LibreReverseLibraryConfiguration(databaseURL: url, keyFileURL: fixture.library.keyFileURL,
            mediaRoot: fixture.library.mediaRoot)
        _ = try LibreReverseLibraryStore.setFrameStarred(frameID: first.id, wallDate: fixture.date,
            isStarred: true, configuration: library)
        _ = try LibreReverseLibraryStore.setFrameStarred(frameID: second.id, wallDate: secondDate,
            isStarred: false, configuration: library)
        _ = try LibreReverseLibraryStore.setFrameStarred(frameID: meeting.frameID, wallDate: meetingDate,
            isStarred: true, configuration: library)
        let plan = try LibreReverseMeetingDeletion.prepare(segmentID: meeting.segmentID, configuration: library)
        try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(plan, configuration: library)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_star WHERE frameId=\(first.id)", library), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_star WHERE frameId=\(second.id)", library), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM shard_star WHERE frameId=\(meeting.frameID)", library), 0)
    }

    func testTranscriptAllocationSharesDurableNamespaceAndReplacementKeepsIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = try XCTUnwrap(LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library).first)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id,
            document: .init(text: "ocr", otherText: "", nodes: []), configuration: fixture.library)
        let ocrID = try scalar("SELECT docid FROM doc_segment WHERE frameId IS NOT NULL", fixture.library)
        let date = fixture.date.addingTimeInterval(2)
        let path = try writeMedia(xid: "transcript", date: date, library: fixture.library)
        let meeting = try LibreReverseLibraryStore.publishMeeting(.init(startDate: date, endDate: date.addingTimeInterval(60),
            relativeMediaPath: path, xid: "transcript", width: 8, height: 8, frameRate: 30,
            audioStartTime: date, duration: 60, transcriptText: "initial transcript"), configuration: fixture.library)
        let id = try XCTUnwrap(meeting.transcriptDocumentID)
        XCTAssertLessThan(id, ocrID)
        let replaced = try LibreReverseLibraryStore.replaceMeetingTranscript(segmentID: meeting.segmentID,
            title: "title", transcriptText: "updated transcript", words: [], configuration: fixture.library)
        XCTAssertEqual(replaced, id)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM doc_segment WHERE docid=\(id)", fixture.library), 1)
    }

    func testTitleJournalsSerializeDifferentMeetingsInOneShardAndAllowRetry() throws {
        let fixture = try makeTwoArchivedMeetings()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try XCTUnwrap(LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[0], title: "First changed", configuration: fixture.library))
        XCTAssertEqual(try LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[0], title: "First changed", configuration: fixture.library), first)
        XCTAssertThrowsError(try LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[1], title: "Second changed", configuration: fixture.library)) { error in
            XCTAssertEqual(error as? LibreReverseMeetingTitleUpdateError,
                           .shardMutationBusy(fixture.segments[1]))
        }
        // An interrupted prepare resumes normally. Only then may another
        // meeting snapshot the shared shard's new content hash.
        try LibreReverseMeetingTitleUpdate.commit(first, configuration: fixture.library)
        let second = try XCTUnwrap(LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[1], title: "Second changed", configuration: fixture.library))
        try LibreReverseMeetingTitleUpdate.commit(second, configuration: fixture.library)
        XCTAssertTrue(try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: fixture.library).isEmpty)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM segment WHERE windowName IN ('First changed','Second changed')", fixture.library), 2)
    }

    func testDeletionJournalsSerializeDifferentMeetingsInOneShardAndAllowRetry() throws {
        let fixture = try makeTwoArchivedMeetings()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[0], configuration: fixture.library)
        XCTAssertEqual(try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[0], configuration: fixture.library), first)
        XCTAssertThrowsError(try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[1], configuration: fixture.library)) { error in
            XCTAssertEqual(error as? LibreReverseMeetingDeletionError,
                           .shardMutationBusy(fixture.segments[1]))
        }
        try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(first, configuration: fixture.library)
        try LibreReverseMeetingDeletion.finishPreparedDeletion(first, configuration: fixture.library)
        let second = try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[1], configuration: fixture.library)
        try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(second, configuration: fixture.library)
        try LibreReverseMeetingDeletion.finishPreparedDeletion(second, configuration: fixture.library)
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: fixture.library).isEmpty)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM segment WHERE type=1", fixture.library), 0)
    }

    func testShardJournalGuardStillExcludesCrossTypeMutations() throws {
        let fixture = try makeTwoArchivedMeetings()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let title = try XCTUnwrap(LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[0], title: "First", configuration: fixture.library))
        XCTAssertThrowsError(try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[1], configuration: fixture.library)) { error in
            XCTAssertEqual(error as? LibreReverseMeetingDeletionError, .shardMutationBusy(fixture.segments[1]))
        }
        try LibreReverseMeetingTitleUpdate.commit(title, configuration: fixture.library)
        let deletion = try LibreReverseMeetingDeletion.prepare(segmentID: fixture.segments[0], configuration: fixture.library)
        XCTAssertThrowsError(try LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[1], title: "Second", configuration: fixture.library)) { error in
            XCTAssertEqual(error as? LibreReverseMeetingTitleUpdateError, .shardMutationBusy(fixture.segments[1]))
        }
        try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(deletion, configuration: fixture.library)
        try LibreReverseMeetingDeletion.finishPreparedDeletion(deletion, configuration: fixture.library)
        let second = try XCTUnwrap(LibreReverseMeetingTitleUpdate.prepare(
            segmentID: fixture.segments[1], title: "Second", configuration: fixture.library))
        try LibreReverseMeetingTitleUpdate.commit(second, configuration: fixture.library)
        XCTAssertTrue(try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: fixture.library).isEmpty)
        XCTAssertTrue(try LibreReverseMeetingDeletion.pendingPlans(configuration: fixture.library).isEmpty)
    }

    private func makeTwoArchivedMeetings() throws -> (root: URL, library: LibreReverseLibraryConfiguration, segments: [Int64]) {
        let fixture = try makeFixture()
        let frame = try XCTUnwrap(LibreReverseLibraryStore.pendingOCRFrames(configuration: fixture.library).first)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id,
            document: .init(text: "screen", otherText: "", nodes: []), configuration: fixture.library)
        var segments: [Int64] = []
        for index in 0..<2 {
            let date = fixture.date.addingTimeInterval(Double(index * 120 + 2))
            let xid = "journal-meeting-\(index)"
            let path = try writeMedia(xid: xid, date: date, library: fixture.library)
            let meeting = try LibreReverseLibraryStore.publishMeeting(.init(startDate: date,
                endDate: date.addingTimeInterval(60), relativeMediaPath: path, xid: xid,
                width: 8, height: 8, frameRate: 30, audioStartTime: date, duration: 60), configuration: fixture.library)
            segments.append(meeting.segmentID)
        }
        let epoch = try LibreReverseShardStore.epochStart(configuration: fixture.library)
        let closed = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let relativePath = "Shards/" + closed.fileName
        let manifest = try LibreReverseShardBuilder.buildToCompletion(source: fixture.library,
            destinationURL: fixture.root.appendingPathComponent(relativePath), interval: closed, batchSize: 1)
        let replacementURL = fixture.root.appendingPathComponent("replacement.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: fixture.library, destinationURL: replacementURL,
            activeInterval: .init(ordinal: 1, epochStart: epoch),
            sealedShards: [.init(manifest: manifest, relativePath: relativePath)])
        return (fixture.root, .init(databaseURL: replacementURL, keyFileURL: fixture.library.keyFileURL,
                                   mediaRoot: fixture.library.mediaRoot), segments)
    }

    private func writeMedia(xid: String, date: Date, library: LibreReverseLibraryConfiguration) throws -> String {
        let path = VideoStorage.relativePath(xid: xid, date: date)
        let url = library.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        return path
    }

    private struct Fixture: Sendable {
        let root: URL
        let library: LibreReverseLibraryConfiguration
        let videoID: Int64
        let mediaURL: URL
        let date: Date
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"),
            mediaRoot: root.appendingPathComponent("Media")
        )
        try LibreReverseLibraryStore.initialize(library)
        let date = Date()
        let frame = try LibreReverseLibraryStore.admitFrame(createdAt: date, imageFileName: "test.png", context: nil, configuration: library)
        let path = VideoStorage.relativePath(xid: "lease-test", date: date)
        let url = library.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        let videoID = try LibreReverseLibraryStore.commitRecordedChunk(
            .init(relativeMediaPath: path, xid: "lease-test", width: 8, height: 8,
                  frames: [.init(frameID: frame.id, videoFrameIndex: 0)]), configuration: library
        )
        return .init(root: root, library: library, videoID: videoID, mediaURL: url, date: date)
    }

    private func withDatabase<T>(_ library: LibreReverseLibraryConfiguration, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: library.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(database, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        return try body(database)
    }

    private func execute(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws {
        try withDatabase(library) { database in
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func scalar(_ sql: String, _ library: LibreReverseLibraryConfiguration) throws -> Int64 {
        try withDatabase(library) { database in
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &raw, nil), SQLITE_OK)
            let statement = try XCTUnwrap(raw)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
    }
}
#endif
