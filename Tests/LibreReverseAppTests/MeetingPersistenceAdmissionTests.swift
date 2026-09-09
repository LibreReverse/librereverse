import Foundation
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class MeetingPersistenceAdmissionTests: XCTestCase {
    func testRecoveryPreventsManualStartAndPrimaryReplacement() {
        XCTAssertFalse(LibreReverseMeetingStartAdmission.canBegin(
            terminating: false, hasActiveSession: false, hasOperationInFlight: false,
            systemCaptureSuspended: false, captureRecoveryInProgress: true))
        XCTAssertFalse(LibreReverseMeetingPersistenceAdmission.canReplacePrimary(
            hasMeetingSession: false, hasMeetingOperation: false, captureRecoveryInProgress: true))
        XCTAssertTrue(LibreReverseMeetingStartAdmission.canBegin(
            terminating: false, hasActiveSession: false, hasOperationInFlight: false,
            systemCaptureSuspended: false, captureRecoveryInProgress: false))
    }

    func testFinalizingMeetingKeepsCurrentPrimaryUntilPublicationThenCatchesUpEveryInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("seed.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(seed)
        let epoch = try LibreReverseShardStore.epochStart(configuration: seed)
        let first = LibreReverseShardInterval(ordinal: 0, epochStart: epoch)
        let current = LibreReverseShardInterval(ordinal: 2, epochStart: epoch)
        let primaryURL = root.appendingPathComponent("library.sqlite3")
        _ = try LibreReverseShardBuilder.buildReplacementPrimary(source: seed, destinationURL: primaryURL,
            activeInterval: first, sealedShards: [])
        let library = LibreReverseLibraryConfiguration(databaseURL: primaryURL,
            keyFileURL: seed.keyFileURL, mediaRoot: seed.mediaRoot)
        let now = current.start.addingTimeInterval(60)
        XCTAssertTrue(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: true, hasMeetingOperation: true, nativeRecordingFinished: true))
        let mayReplace = LibreReverseMeetingPersistenceAdmission.canReplacePrimary(
            hasMeetingSession: true, hasMeetingOperation: true, captureRecoveryInProgress: false)
        if mayReplace {
            _ = try LibreReverseShardRollover.performIfNeeded(at: now, configuration: library)
        }
        XCTAssertEqual(try LibreReverseShardStore.activeOrdinal(configuration: library), 0)
        // Native recording is closed, so new sparse frames can still be admitted
        // while the meeting's older payload awaits speech finalization.
        let frame = try LibreReverseLibraryStore.admitFrame(createdAt: now, imageFileName: "sparse.png",
            context: .init(bundleID: "test.editor", windowName: "Current work"), configuration: library)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id,
            document: .init(text: "currentwork", otherText: "", nodes: []), configuration: library)
        let start = first.start.addingTimeInterval(60)
        let path = VideoStorage.relativePath(xid: "late-meeting", date: start)
        let media = library.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: media)
        let meeting = try LibreReverseLibraryStore.publishMeeting(.init(
            startDate: start, endDate: start.addingTimeInterval(60), windowName: "Older meeting",
            relativeMediaPath: path, xid: "late-meeting", width: 8, height: 8, frameRate: 30,
            audioStartTime: start, duration: 60, transcriptText: "publicationneedle"), configuration: library)
        XCTAssertTrue(LibreReverseMeetingPersistenceAdmission.canReplacePrimary(
            hasMeetingSession: false, hasMeetingOperation: false, captureRecoveryInProgress: false))
        let rollover = try XCTUnwrap(LibreReverseShardRollover.performIfNeeded(at: now, configuration: library))
        XCTAssertEqual(rollover.primary.activeInterval.ordinal, 2)
        let reader = LibraryDatabaseSession(configuration: .init(databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL, mediaRoot: library.mediaRoot))
        let old = try await reader.recencySearchCandidates(query: "publicationneedle", facets: .init(isTranscript: true))
        let live = try await reader.recencySearchCandidates(query: "currentwork")
        await reader.closeConnection()
        XCTAssertEqual(old.map(\.segmentID), [meeting.segmentID])
        XCTAssertEqual(live.map(\.frameID), [frame.id])
    }
}
