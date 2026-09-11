import Foundation
import XCTest
@testable import LibreReverseApp

final class OpenRouterEventStreamTests: XCTestCase {
    private func parse(_ stream: String) throws -> LibreReverseOpenRouterEventStream {
        var parser = LibreReverseOpenRouterEventStream()
        for byte in stream.utf8 { try parser.consume(byte) }
        return parser
    }
    func testUTF8CommentsMultilineDataAndUsageProduceOnlyVisibleAnswer() throws {
        var parser = try parse(": keepalive\r\ndata: {\"choices\":\r\ndata: [{\"delta\":{\"content\":\"Hello 漢👩🏽‍💻\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{}}\n\ndata: [DONE]\n\n")
        XCTAssertEqual(try parser.finish(), .complete("Hello 漢👩🏽‍💻"))
        XCTAssertTrue(parser.isDone)
    }
    func testReasoningOnlyUpdatesCountersAndNeverAppearsInProgressOrAnswer() throws {
        var parser = try parse("data: {\"choices\":[{\"delta\":{\"reasoning\":\"RAW_REASONING_SECRET\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"reasoning_details\":[{\"text\":\"RAW_DETAIL_SECRET\"}]},\"finish_reason\":null}]}\n\n")
        XCTAssertEqual(parser.processingUpdates, 2)
        XCTAssertFalse(parser.progressMessage.contains("RAW_"))
        for byte in "data: {\"choices\":[{\"delta\":{\"content\":\"Visible answer\"},\"finish_reason\":\"stop\"}]}\n\n".utf8 { try parser.consume(byte) }
        XCTAssertEqual(try parser.finish(), .complete("Visible answer"))
        XCTAssertFalse(parser.progressMessage.contains("RAW_"))
    }
    func testLengthLimitIsNotSuccessfulPartialAnswer() throws {
        var parser = try parse("data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n")
        XCTAssertEqual(try parser.finish(), .lengthLimited)
    }
    func testInterruptedMalformedFilteredAndErrorStreamsAreRejected() throws {
        for stream in [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}\n\n",
            "data: [DONE]\n\n", "data: not-json\n\n",
            "data: {\"error\":{\"message\":\"private vendor detail\"}}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"error\"}]}\n\n"
        ] {
            XCTAssertThrowsError(try { var parser = try parse(stream); return try parser.finish() }())
        }
    }
    func testRepeatedTerminalUsageFrameIsAcceptedButContradictionIsRejected() throws {
        let completed = "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"},\"finish_reason\":\"stop\"}]}\n\n"
        let usage = "data: {\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":10}}\n\ndata: [DONE]\n\n"
        var parser = try parse(completed + usage)
        XCTAssertEqual(try parser.finish(), .complete("Answer"))
        XCTAssertThrowsError(try parse(completed + usage.replacingOccurrences(of: "stop", with: "length")))
    }

    func testFinalEventWithoutTrailingNewlineIsAcceptedWhenComplete() throws {
        var parser = try parse("data: {\"choices\":[{\"delta\":{\"content\":\"Complete\"},\"finish_reason\":\"stop\"}]}")
        XCTAssertEqual(try parser.finish(), .complete("Complete"))
    }
    func testStreamSizeLimitIsBounded() {
        var parser = LibreReverseOpenRouterEventStream(byteLimit: 16)
        XCTAssertThrowsError(try String(repeating: "x", count: 100).utf8.forEach { try parser.consume($0) })
    }
}
