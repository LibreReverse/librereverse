import XCTest
@testable import LibreReverseCore

final class RecordingDiagnosticsTests: XCTestCase {
    func testErrorsAndRecoveryPersistWithBoundedRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LibreReverseRecordingDiagnostics.append(to: directory, event: "error",
            operation: "sparseCapture", error: NSError(domain: "CaptureTest", code: 42))
        let url = directory.appendingPathComponent("recording.jsonl")
        let data = try Data(contentsOf: url)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["errorCode"] as? Int, 42)
        XCTAssertEqual(record["errorDomain"] as? String, "CaptureTest")
        try LibreReverseRecordingDiagnostics.append(to: directory, event: "recovered",
            operation: "sparseCapture", maximumBytes: data.count)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recording.previous.jsonl")), data)
        let recovered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(recovered["event"] as? String, "recovered")
        XCTAssertNil(recovered["errorCode"])
    }
}
