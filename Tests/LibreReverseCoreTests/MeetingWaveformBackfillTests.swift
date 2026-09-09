#if os(macOS)
import CSQLCipher
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingWaveformBackfillTests: XCTestCase {
    func testDiscoveryOnlyIncludesCanonicalLocalMeetingsAndRetryClearsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("media"))
        try LibreReverseLibraryStore.initialize(configuration)
        try FileManager.default.createDirectory(at: configuration.mediaRoot, withIntermediateDirectories: true)
        for name in ["meeting.mp4", "screen.mp4"] {
            try Data([1, 2, 3]).write(to: configuration.mediaRoot.appendingPathComponent(name))
        }
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(database, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            INSERT INTO video(id,path,captureType,width,height) VALUES
              (1,'meeting.mp4','meeting',100,100),(2,'screen.mp4','screen',100,100),
              (3,'remote.mp4','meeting',100,100),(4,'../outside.mp4','meeting',100,100);
            INSERT INTO media_residency(videoId,localState,desiredLocal) VALUES(1,'present',1);
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try MeetingWaveformBackfill.candidates(configuration: configuration).map(\.videoID), [1])
        let failed = try await MeetingWaveformBackfill.run(configuration: configuration, prepare: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        XCTAssertNotNil(failed.failures["1"])
        XCTAssertNil(failed.completed["1"])
        let completed = try await MeetingWaveformBackfill.run(configuration: configuration, prepare: { _ in })
        XCTAssertNotNil(completed.completed["1"])
        XCTAssertTrue(completed.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: configuration.mediaRoot.appendingPathComponent("meeting.mp4")), Data([1, 2, 3]))
    }
}
#endif
