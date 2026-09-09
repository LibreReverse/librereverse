import XCTest

@testable import LibreReverseCore

final class MeetingTranscriptInteractionPolicyTests: XCTestCase {
    func testSourceOnlyTranscriptRepairRebuildsFollowerText() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = transcript(
            start: start,
            word: .init(
                id: 1,
                speechSource: "unknown",
                text: "hello",
                startSeconds: 0,
                durationSeconds: 1,
                fullTextUTF16Offset: 0
            )
        )
        let repaired = transcript(
            start: start,
            word: .init(
                id: 1,
                speechSource: "me",
                text: "hello",
                startSeconds: 0,
                durationSeconds: 1,
                fullTextUTF16Offset: 0
            )
        )

        XCTAssertTrue(
            LibreReverseMeetingTranscriptInteractionPolicy.requiresTextRebuild(
                previous: original,
                next: repaired
            )
        )
        XCTAssertFalse(
            LibreReverseMeetingTranscriptInteractionPolicy.requiresTextRebuild(
                previous: repaired,
                next: repaired
            )
        )
    }

    func testHeaderOnlyMetadataRefreshPreservesNativeTranscriptSelection() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let word = LibreReverseMeetingTranscriptWord(
            id: 1,
            speechSource: "me",
            text: "hello",
            startSeconds: 0,
            durationSeconds: 1,
            fullTextUTF16Offset: 0
        )
        let original = transcript(start: start, word: word)
        let updated = LibreReverseMeetingTranscript(
            segmentID: original.segmentID,
            title: original.title,
            text: original.text,
            startDate: original.startDate,
            endDate: original.endDate,
            words: original.words,
            metadata: .init(
                provider: .zoom,
                calendarTitle: "Work",
                participants: ["Ada", "Grace"]
            ),
            processingState: original.processingState
        )

        XCTAssertFalse(
            LibreReverseMeetingTranscriptInteractionPolicy.requiresTextRebuild(
                previous: original,
                next: updated
            )
        )
    }

    func testUserSelectionInterruptsPlaybackBeforeHighlightRebuild() {
        XCTAssertTrue(
            LibreReverseMeetingTranscriptInteractionPolicy.interruptsPlayback(
                .userTextSelection
            )
        )
    }

    func testProgrammaticWordFollowingDoesNotInterruptPlayback() {
        XCTAssertFalse(
            LibreReverseMeetingTranscriptInteractionPolicy.interruptsPlayback(
                .programmaticWordFollow
            )
        )
    }

    func testLinkRangeAcceptsExactUTF16Boundaries() {
        XCTAssertEqual(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 5,
                offset: 0
            ),
            NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 5,
                offset: 7
            ),
            NSRange(location: 7, length: 5)
        )
    }

    func testLinkRangeRejectsMissingNegativeEmptyAndOutOfBoundsValues() {
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 5,
                offset: nil
            ))
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 5,
                offset: -1
            ))
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 0,
                offset: 0
            ))
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: 6,
                offset: 7
            ))
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: -1,
                wordTextUTF16Length: 1,
                offset: 0
            ))
    }

    func testLinkRangeRejectsOverflowingInputsWithoutAddingThem() {
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: 12,
                wordTextUTF16Length: Int.max,
                offset: 1
            ))
        XCTAssertNil(
            LibreReverseMeetingTranscriptInteractionPolicy.linkRange(
                fullTextUTF16Length: Int.max,
                wordTextUTF16Length: 2,
                offset: Int.max
            ))
    }

    private func transcript(
        start: Date,
        word: LibreReverseMeetingTranscriptWord
    ) -> LibreReverseMeetingTranscript {
        .init(
            segmentID: 1,
            title: "Meeting",
            text: "hello",
            startDate: start,
            endDate: start.addingTimeInterval(10),
            words: [word],
            processingState: .complete
        )
    }
}
