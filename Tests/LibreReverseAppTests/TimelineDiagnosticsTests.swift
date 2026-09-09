#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseApp

final class TimelineDiagnosticsTests: XCTestCase {
    func testTraceCategoriesDiscardQueriesPathsTitlesAndErrors() {
        XCTAssertEqual(LibreReverseTimelineTrace.eventCategory("SEARCHPAGE failed=secret document title"), "SEARCHPAGE")
        XCTAssertEqual(LibreReverseTimelineTrace.eventCategory("render selected /Users/example/private-recording.mp4"), "RENDER")
        XCTAssertEqual(LibreReverseTimelineTrace.eventCategory("sensitive search phrase"), "EVENT")
        XCTAssertEqual(LibreReverseTimelineTrace.eventCategory("https://private.example/path"), "EVENT")
    }

    func testDiagnosticFileStopsAtByteBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("diagnostic.log")
        let log = try XCTUnwrap(LibreReverseBoundedDiagnosticLog(url: url, maximumBytes: 16))
        log.append("12345678")
        log.append("abcdefgh")
        log.append("must not be written")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "12345678abcdefgh")
    }

    func testDiagnosticFileRefusesSymlinkDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("preserve.txt")
        let link = root.appendingPathComponent("diagnostic.log")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(LibreReverseBoundedDiagnosticLog(url: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
    }
}
#endif
