import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class MeetingDetectionDiagnosticsTests: XCTestCase {
    func testDiagnosticLifecycleNeverSerializesMeetingContentAndLogRotates() throws {
        let candidate = LibreReverseMeetingCandidate(provider: .googleMeet, source: .windowDetection,
            title: "private meeting title", url: URL(string: "https://meet.google.com/secret-room"))
        let state = LibreReverseMeetingLifecycleState.candidate(candidate, observations: 1)
        let record = LibreReverseMeetingDetectionDiagnostics.Record(
            timestamp: Date(timeIntervalSince1970: 0), phase: "observed", policy: "automatic",
            lifecycle: LibreReverseMeetingDetectionDiagnostics.lifecycleName(state),
            counters: ["browserReason_2": 1, "candidatesAfterIgnore": 0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LibreReverseMeetingDetectionDiagnostics.append(record, to: directory, maximumBytes: 1)
        try LibreReverseMeetingDetectionDiagnostics.append(record, to: directory, maximumBytes: 1)
        for name in ["meeting-detection.jsonl", "meeting-detection.previous.jsonl"] {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("candidate"))
            XCTAssertFalse(text.contains("private meeting"))
            XCTAssertFalse(text.contains("secret-room"))
            XCTAssertFalse(text.contains("meet.google.com"))
            XCTAssertEqual(text.split(separator: "\n").count, 1)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(decoded["counters"] as? [String: Int], record.counters)
        }
    }

}
