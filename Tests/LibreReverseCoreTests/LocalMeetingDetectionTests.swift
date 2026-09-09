import XCTest
@testable import LibreReverseCore
final class LocalMeetingDetectionTests: XCTestCase {
    func testOnlyExplicitLocalMeetingFixtureStartsCapture() throws {
        let active = try XCTUnwrap(URL(string: "http://127.0.0.1:8768/librereverse-meeting-test.html?active=1"))
        XCTAssertEqual(LibreReverseMeetingDetector.browserProvider(for: active), .localTest)
        for value in ["http://127.0.0.1:8768/librereverse-meeting-test.html", "http://127.0.0.1:8768/librereverse-meeting-test.html?active=0", "http://example.com:8768/librereverse-meeting-test.html?active=1", "http://127.0.0.1:8769/librereverse-meeting-test.html?active=1", "http://127.0.0.1:8768/other?active=1"] {
            XCTAssertNil(LibreReverseMeetingDetector.browserProvider(for: try XCTUnwrap(URL(string:value))))
        }
    }
}
