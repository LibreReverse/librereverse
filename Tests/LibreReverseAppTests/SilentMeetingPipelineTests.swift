#if os(macOS)
import Foundation
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class SilentMeetingPipelineTests: XCTestCase {
    func testSyntheticMeetingTranscribesPersistsAndSummarizesLocallyWithoutPlayback() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["LIBREREVERSE_SILENT_MEETING_FIXTURE"],
              let runtimePath = ProcessInfo.processInfo.environment["LIBREREVERSE_TEST_WHISPER_RUNTIME"] else {
            throw XCTSkip("Opt-in real local-model test; requires synthetic media and an explicit native runtime.")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/key"), mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(library)
        let date = Date(timeIntervalSince1970: 1_788_552_000)
        let xid = XID.generate(at: date)
        let relativePath = VideoStorage.relativePath(xid: xid, date: date)
        let canonical = library.mediaRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: canonical)
        let meeting = try LibreReverseLibraryStore.publishMeeting(.init(
            startDate: date, endDate: date.addingTimeInterval(21), windowName: "Silent pipeline test",
            relativeMediaPath: relativePath, xid: xid, width: 640, height: 360, frameRate: 30,
            audioStartTime: date, duration: 21), configuration: library)
        let queue = LibreReverseMeetingTranscriptionQueue(root: root.appendingPathComponent("TranscriptionQueue"))
        try queue.enqueue(.init(publicationXID: xid, segmentID: meeting.segmentID, videoID: meeting.videoID,
            title: "Silent pipeline test", relativeMediaPath: relativePath, createdAt: date))
        let transcriber = WhisperCPPCLITranscriber(configuration: .init(
            executableURL: runtime.appendingPathComponent("bin/whisper-cli"),
            modelURL: runtime.appendingPathComponent("Models/ggml-large-v3-turbo.bin"), language: "en", useGPU: true))
        let run = await LibreReverseMeetingTranscriptionRunner(queue: queue, library: library, transcriber: transcriber).runReady()
        let failures = try queue.pending().compactMap(\.lastError).joined(separator: "\n")
        XCTAssertEqual(run.completed, 1, failures)
        XCTAssertEqual(run.failed, 0, failures)
        let job = try XCTUnwrap(LibreReverseLibraryStore.pendingMeetingSummaries(configuration: library).first)
        XCTAssertTrue(job.transcript.contains("Friday"))
        XCTAssertTrue(job.transcript.contains("Alex"))
        let summary = try await LibreReverseMeetingSummarizer.summarize(job.transcript)
        XCTAssertTrue(summary.contains("Friday"))
        XCTAssertTrue(summary.contains("Alex"))
        try LibreReverseLibraryStore.finishMeetingSummary(eventID: job.eventID, text: summary, configuration: library)
        let session = LibraryDatabaseSession(configuration: .init(databaseURL: library.databaseURL,
            keyFileURL: library.keyFileURL, mediaRoot: library.mediaRoot))
        let savedSummary = try await session.meetingSummary(segmentID: meeting.segmentID)
        let transcript = try await session.meetingTranscript(segmentID: meeting.segmentID, at: date)
        XCTAssertEqual(savedSummary, summary)
        XCTAssertFalse(try XCTUnwrap(transcript).words.isEmpty)
        await session.closeConnection()
    }
}
#endif
