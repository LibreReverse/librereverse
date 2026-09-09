#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class CapturePublicationContentionTests: XCTestCase {
    func testMeetingPublicationCannotInvalidateCaptureAdmissionSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("media"))
        try LibreReverseLibraryStore.initialize(configuration)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = LibreReverseLibraryWriteSession(configuration: configuration)
        defer { session.close() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try LibreReverseLibraryStore.admitFrame(createdAt: start,
            imageFileName: "first.png", context: nil, configuration: configuration, session: session)
        let xid = "capturecontentiontest"
        let path = VideoStorage.relativePath(xid: xid, date: start)
        let media = configuration.mediaRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: media)
        let meeting = LibreReverseMeetingPublication(startDate: start,
            endDate: start.addingTimeInterval(10), relativeMediaPath: path, xid: xid,
            width: 100, height: 100, frameRate: 30, audioStartTime: start, duration: 10)
        let race = PublicationAfterCaptureRead {
            try LibreReverseLibraryStore.publishMeeting(meeting, configuration: configuration)
        }
        let context = Unmanaged.passUnretained(race).toOpaque()
        try session.withDatabase(configuration: configuration) { database in
            sqlite3_trace_v2(database, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement,
                      let sql = sqlite3_sql(OpaquePointer(statement)),
                      String(cString: sql).contains("FROM segment WHERE type=0 ORDER BY") else { return 0 }
                Unmanaged<PublicationAfterCaptureRead>.fromOpaque(context).takeUnretainedValue().afterRead()
                return 0
            }, context)
        }
        var admitted: LibreReverseAdmittedFrame?
        var admissionError: Error?
        do {
            admitted = try LibreReverseLibraryStore.admitFrame(createdAt: start.addingTimeInterval(5),
                imageFileName: "second.png", context: nil, configuration: configuration, session: session)
        } catch { admissionError = error }
        // Drain the publisher even when testing the old broken implementation,
        // so teardown cannot race a still-owned connection or hide its result.
        XCTAssertEqual(race.finished.wait(timeout: .now() + 5), .success)
        try session.withDatabase(configuration: configuration) { database in
            sqlite3_trace_v2(database, 0, nil, nil)
        }
        XCTAssertTrue(race.didTrigger)
        XCTAssertNil(admissionError, "Concurrent publication must not fail screenshot admission: \(String(describing: admissionError))")
        let published = try race.result.get()
        XCTAssertNotEqual(published.frameID, first.id)
        if let admitted {
            XCTAssertEqual(admitted.segmentID, first.segmentID)
            XCTAssertNotEqual(admitted.id, published.frameID)
            XCTAssertEqual(try LibreReverseLibraryStore.loadRecoverableFrames(
                configuration: configuration).map(\.id), [first.id, admitted.id])
            XCTAssertEqual(try LibreReverseLibraryStore.pendingOCRFrameIDs(
                configuration: configuration), [first.id, admitted.id])
        }
        XCTAssertNotNil(try LibreReverseLibraryStore.publishedMeeting(xid: xid, configuration: configuration))
    }
}

private final class PublicationAfterCaptureRead: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var triggered = false
    private var publicationResult: Result<LibreReversePublishedMeeting, Error>?
    private let publish: @Sendable () throws -> LibreReversePublishedMeeting
    init(publish: @escaping @Sendable () throws -> LibreReversePublishedMeeting) { self.publish = publish }
    var didTrigger: Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    var result: Result<LibreReversePublishedMeeting, Error> {
        lock.lock(); defer { lock.unlock() }
        return publicationResult ?? .failure(NSError(domain: "PublicationDidNotFinish", code: 1))
    }
    func afterRead() {
        lock.lock()
        guard !triggered else { lock.unlock(); return }
        triggered = true
        lock.unlock()
        let attemptFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let result = Result { try self.publish() }
            self.lock.lock(); self.publicationResult = result; self.lock.unlock()
            attemptFinished.signal()
            self.finished.signal()
        }
        // With DEFERRED, publication commits while admission's read snapshot is
        // held. With IMMEDIATE, its writer waits until this admission commits.
        // Bounded wait releases capture in that expected serialization case.
        _ = attemptFinished.wait(timeout: .now() + 2)
    }
}
#endif
