import Foundation
import XCTest

@testable import LibreReverseCore

final class MeetingTranscriptExportTests: XCTestCase {
    func testPlainTextExportCarriesDetailsAndTranscript() {
        let transcript = fixture(title: "Design review")
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.plainText(transcript),
            """
            Design review
            2026-08-27T16:00:00Z – 2026-08-27T16:02:05Z
            Duration: 2m 05s

            hello from the meeting
            """
        )
    }

    func testSuggestedFileNameRemovesPathAndControlCharacters() {
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.suggestedFileName(
                fixture(title: "Roadmap/Q3: review\nnotes")
            ),
            "Roadmap-Q3- review-notes.txt"
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.suggestedFileName(fixture(title: "  ")),
            "Meeting transcript.txt"
        )
    }

    func testPlainTextExportIncludesPersistedMeetingContext() {
        let transcript = fixture(
            title: "Design review",
            metadata: .init(
                provider: .googleMeet,
                source: .windowDetection,
                calendarTitle: "Work",
                participants: ["Ada", "Grace"],
                calendarID: "calendar-work",
                calendarEventID: "event-42",
                calendarSeriesID: "series-42"
            )
        )

        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.plainText(transcript),
            """
            Design review
            2026-08-27T16:00:00Z – 2026-08-27T16:02:05Z
            Duration: 2m 05s
            Provider: Google Meet
            Calendar: Work
            Participants: Ada, Grace

            hello from the meeting
            """
        )
    }

    func testEmptyTranscriptStillExportsMeetingDetailsWithoutInventingText() {
        let transcript = fixture(
            title: "Quiet meeting",
            text: "  \n ",
            metadata: .init(provider: .zoom, participants: ["Ada"])
        )

        XCTAssertFalse(transcript.hasTranscriptText)
        let exported = LibreReverseMeetingTranscriptExport.plainText(transcript)
        XCTAssertTrue(exported.contains("Quiet meeting\n"))
        XCTAssertTrue(exported.contains("Provider: Zoom\n"))
        XCTAssertTrue(exported.contains("Participants: Ada\n"))
        XCTAssertTrue(exported.hasSuffix("\n\n  \n "))
    }

    func testWebVTTExportPreservesExactLegacyWordTimingAndEscapesCueMarkup() {
        let transcript = fixture(
            title: "Design\nreview",
            words: [
                .init(
                    id: 7,
                    speechSource: "system",
                    text: "hello <team>",
                    startSeconds: 1.25,
                    durationSeconds: 0.5,
                    fullTextUTF16Offset: 0
                ),
                .init(
                    id: 8,
                    speechSource: "microphone",
                    text: "next --> item",
                    startSeconds: 61.001,
                    durationSeconds: 0,
                    fullTextUTF16Offset: 13
                ),
            ]
        )

        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.webVTT(transcript),
            """
            WEBVTT

            NOTE
            Title: Design review
            Start: 2026-08-27T16:00:00Z
            End: 2026-08-27T16:02:05Z

            word-0-7
            00:00:01.250 --> 00:00:01.750
            hello &lt;team&gt;

            word-1-8
            00:01:01.001 --> 00:01:01.002
            next → item

            """
        )
    }

    func testWebVTTExportSkipsCorruptLegacyCuesAndKeepsValidNeighbors() {
        let transcript = fixture(
            title: "Corrupt legacy timing",
            words: [
                .init(
                    id: 1,
                    speechSource: "system",
                    text: "negative",
                    startSeconds: -1,
                    durationSeconds: 1,
                    fullTextUTF16Offset: nil
                ),
                .init(
                    id: 2,
                    speechSource: "system",
                    text: "not finite",
                    startSeconds: .nan,
                    durationSeconds: 1,
                    fullTextUTF16Offset: nil
                ),
                .init(
                    id: 3,
                    speechSource: "system",
                    text: "overflow",
                    startSeconds: .greatestFiniteMagnitude,
                    durationSeconds: .greatestFiniteMagnitude,
                    fullTextUTF16Offset: nil
                ),
                .init(
                    id: 0,
                    speechSource: "system",
                    text: "bad identity",
                    startSeconds: 1,
                    durationSeconds: 1,
                    fullTextUTF16Offset: nil
                ),
                .init(
                    id: 9,
                    speechSource: "microphone",
                    text: "survives",
                    startSeconds: 2.5,
                    durationSeconds: 0.25,
                    fullTextUTF16Offset: nil
                ),
            ]
        )

        let exported = LibreReverseMeetingTranscriptExport.webVTT(transcript)
        XCTAssertFalse(exported.contains("negative"))
        XCTAssertFalse(exported.contains("not finite"))
        XCTAssertFalse(exported.contains("overflow"))
        XCTAssertFalse(exported.contains("bad identity"))
        XCTAssertTrue(
            exported.contains(
                "word-4-9\n00:00:02.500 --> 00:00:02.750\nsurvives"
            ))
    }

    func testLosslessJSONCarriesIdentityMetadataProcessingAndEveryWordField() throws {
        let retryAt = ISO8601DateFormatter().date(from: "2026-08-27T17:00:00Z")!
        let transcript = fixture(
            title: "Design review",
            metadata: .init(
                provider: .microsoftTeamsV2,
                source: .windowDetection,
                calendarTitle: "Engineering",
                participants: ["Ada", "Grace"],
                calendarID: "calendar-1",
                calendarEventID: "event-1",
                calendarSeriesID: "series-1"
            ),
            processingState: .retrying(attempt: 3, retryAfter: retryAt),
            words: [
                .init(
                    id: 99,
                    speechSource: "microphone",
                    text: "hello",
                    startSeconds: 2,
                    durationSeconds: 1,
                    fullTextUTF16Offset: 4
                )
            ]
        )

        let data = try LibreReverseMeetingTranscriptExport.data(
            transcript,
            format: .losslessJSON
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schema"] as? String, "librereverse.meeting-transcript")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["segmentID"] as? Int64, 42)
        let metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["provider"] as? String, "teams2")
        XCTAssertEqual(metadata["source"] as? String, "windowDetection")
        XCTAssertEqual(metadata["calendarEventID"] as? String, "event-1")
        let processing = try XCTUnwrap(object["processing"] as? [String: Any])
        XCTAssertEqual(processing["state"] as? String, "retrying")
        XCTAssertEqual(processing["attempt"] as? Int, 3)
        XCTAssertEqual(processing["retryAfter"] as? String, "2026-08-27T17:00:00Z")
        let words = try XCTUnwrap(object["words"] as? [[String: Any]])
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0]["id"] as? Int64, 99)
        XCTAssertEqual(words[0]["speechSource"] as? String, "microphone")
        XCTAssertEqual(words[0]["startSeconds"] as? Double, 2)
        XCTAssertEqual(words[0]["durationSeconds"] as? Double, 1)
        XCTAssertEqual(words[0]["fullTextUTF16Offset"] as? Int, 4)
        XCTAssertEqual(
            try LibreReverseMeetingTranscriptExport.transcript(fromLosslessJSON: data),
            transcript
        )
    }

    func testLosslessJSONImportFailsClosedForUnknownSchemaAndVersion() throws {
        let transcript = fixture(title: "Review")
        let data = try LibreReverseMeetingTranscriptExport.data(
            transcript,
            format: .losslessJSON
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schema"] = "somewhere-else"
        let wrongSchema = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try LibreReverseMeetingTranscriptExport.transcript(fromLosslessJSON: wrongSchema)
        ) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .invalidSchema("somewhere-else")
            )
        }

        object["schema"] = "librereverse.meeting-transcript"
        object["version"] = 2
        let futureVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try LibreReverseMeetingTranscriptExport.transcript(fromLosslessJSON: futureVersion)
        ) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .unsupportedVersion(2)
            )
        }
    }

    func testLosslessJSONImportRejectsInvalidMeetingIdentityAndDateRange() throws {
        var object = try losslessObject(fixture(title: "Review"))
        object["segmentID"] = 0
        XCTAssertThrowsError(try importLossless(object)) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .invalidSegmentID(0)
            )
        }

        object = try losslessObject(fixture(title: "Review"))
        object["endDate"] = "2026-08-27T15:59:59Z"
        XCTAssertThrowsError(try importLossless(object)) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .invalidDateRange
            )
        }
    }

    func testLosslessJSONImportRejectsCorruptWordTimingIdentityOrderAndOffsets() throws {
        let transcript = fixture(
            title: "Review",
            words: [
                .init(
                    id: 1,
                    speechSource: "system",
                    text: "hello",
                    startSeconds: 1,
                    durationSeconds: 0.5,
                    fullTextUTF16Offset: 0
                ),
                .init(
                    id: 2,
                    speechSource: "microphone",
                    text: "meeting",
                    startSeconds: 2,
                    durationSeconds: 0.5,
                    fullTextUTF16Offset: 6
                ),
            ]
        )

        try assertInvalidWord(
            transcript,
            mutate: { $0[0]["id"] = 0 },
            expected: .invalidWordIdentity(0)
        )
        try assertInvalidWord(
            transcript,
            mutate: { $0[0]["durationSeconds"] = -0.5 },
            expected: .invalidWordTiming(0)
        )
        try assertInvalidWord(
            transcript,
            mutate: { $0[1]["startSeconds"] = 0.5 },
            expected: .invalidWordOrder(1)
        )
        try assertInvalidWord(
            transcript,
            mutate: { $0[1]["fullTextUTF16Offset"] = 999 },
            expected: .invalidWordOffset(1)
        )
        try assertInvalidWord(
            transcript,
            mutate: {
                $0[1]["fullTextUTF16Offset"] = 0
                $0[0]["fullTextUTF16Offset"] = 1
            },
            expected: .invalidWordOffset(1)
        )
    }

    func testLosslessJSONImportRejectsContradictoryProcessingState() throws {
        var object = try losslessObject(fixture(title: "Review"))
        var processing = try XCTUnwrap(object["processing"] as? [String: Any])
        processing["state"] = "complete"
        processing["attempt"] = 3
        object["processing"] = processing
        XCTAssertThrowsError(try importLossless(object)) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .invalidRetryState
            )
        }

        processing["state"] = "retrying"
        processing["attempt"] = 0
        object["processing"] = processing
        XCTAssertThrowsError(try importLossless(object)) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                .invalidRetryState
            )
        }
    }

    func testFormatSelectionAndSuggestedExtensionsAreDeterministic() {
        let transcript = fixture(title: "Review")
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.format(for: URL(fileURLWithPath: "/tmp/a.VTT")),
            .webVTT
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.format(for: URL(fileURLWithPath: "/tmp/a.json")),
            .losslessJSON
        )
        XCTAssertNil(
            LibreReverseMeetingTranscriptExport.format(for: URL(fileURLWithPath: "/tmp/a.md"))
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.suggestedFileName(
                transcript,
                format: .webVTT
            ),
            "Review.vtt"
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptExport.suggestedFileName(
                transcript,
                format: .losslessJSON
            ),
            "Review.json"
        )
    }

    private func fixture(
        title: String,
        text: String = "hello from the meeting",
        metadata: LibreReverseMeetingTranscriptMetadata = .init(),
        processingState: LibreReverseMeetingTranscriptProcessingState = .unavailable,
        words: [LibreReverseMeetingTranscriptWord] = []
    ) -> LibreReverseMeetingTranscript {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T16:00:00Z")!
        return .init(
            segmentID: 42,
            title: title,
            text: text,
            startDate: start,
            endDate: start.addingTimeInterval(125),
            words: words,
            metadata: metadata,
            processingState: processingState
        )
    }

    private func losslessObject(_ transcript: LibreReverseMeetingTranscript) throws
        -> [String: Any]
    {
        let data = try LibreReverseMeetingTranscriptExport.data(transcript, format: .losslessJSON)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func importLossless(_ object: [String: Any]) throws
        -> LibreReverseMeetingTranscript
    {
        try LibreReverseMeetingTranscriptExport.transcript(
            fromLosslessJSON: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func assertInvalidWord(
        _ transcript: LibreReverseMeetingTranscript,
        mutate: (inout [[String: Any]]) -> Void,
        expected: LibreReverseMeetingTranscriptExport.LosslessJSONError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var object = try losslessObject(transcript)
        var words = try XCTUnwrap(object["words"] as? [[String: Any]])
        mutate(&words)
        object["words"] = words
        XCTAssertThrowsError(try importLossless(object), file: file, line: line) {
            XCTAssertEqual(
                $0 as? LibreReverseMeetingTranscriptExport.LosslessJSONError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
