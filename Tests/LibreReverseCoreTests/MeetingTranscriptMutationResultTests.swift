import XCTest

@testable import LibreReverseCore

final class MeetingTranscriptMutationResultTests: XCTestCase {
    func testConfirmationCanBeginOnlyWhileCapturedMeetingStillOwnsFollower() {
        XCTAssertTrue(
            LibreReverseMeetingTranscriptMutationResult.canBegin(
                operationSegmentID: 42,
                selectedSegmentID: 42
            )
        )
        XCTAssertFalse(
            LibreReverseMeetingTranscriptMutationResult.canBegin(
                operationSegmentID: 42,
                selectedSegmentID: 84
            )
        )
        XCTAssertFalse(
            LibreReverseMeetingTranscriptMutationResult.canBegin(
                operationSegmentID: 42,
                selectedSegmentID: nil
            )
        )
    }

    func testTitleResultMergesIntoLatestTranscriptSnapshot() {
        let latest = fixture(segmentID: 42, title: "Before", text: "new words")
        let updated = LibreReverseMeetingTranscriptMutationResult.applyingTitle(
            "After",
            operationSegmentID: 42,
            to: latest
        )

        XCTAssertEqual(updated?.title, "After")
        XCTAssertEqual(updated?.text, "new words")
        XCTAssertEqual(updated?.processingState, .complete)
        XCTAssertEqual(updated?.words, latest.words)
        XCTAssertEqual(updated?.metadata, latest.metadata)
    }

    func testContextResultCannotOverwriteANewerMeetingSelection() {
        let newerSelection = fixture(segmentID: 84, title: "Other", text: "other words")
        let result = LibreReverseMeetingTranscriptMutationResult.applyingContext(
            .init(participants: ["Ada"], calendarTitle: "Work"),
            operationSegmentID: 42,
            to: newerSelection
        )

        XCTAssertEqual(result, newerSelection)
    }

    func testDeletionClearsOnlyTheStillSelectedTargetMeeting() {
        let target = fixture(segmentID: 42, title: "Delete", text: "gone")
        let newerSelection = fixture(segmentID: 84, title: "Keep", text: "present")

        XCTAssertNil(
            LibreReverseMeetingTranscriptMutationResult.applyingDeletion(
                operationSegmentID: 42,
                to: target
            )
        )
        XCTAssertEqual(
            LibreReverseMeetingTranscriptMutationResult.applyingDeletion(
                operationSegmentID: 42,
                to: newerSelection
            ),
            newerSelection
        )
    }

    private func fixture(
        segmentID: Int64,
        title: String,
        text: String
    ) -> LibreReverseMeetingTranscript {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(
            segmentID: segmentID,
            title: title,
            text: text,
            startDate: start,
            endDate: start.addingTimeInterval(60),
            words: [
                .init(
                    id: 1,
                    speechSource: "others",
                    text: text,
                    startSeconds: 1,
                    durationSeconds: 1,
                    fullTextUTF16Offset: 0
                )
            ],
            metadata: .init(
                provider: .zoom,
                calendarTitle: "Engineering",
                participants: ["Grace"]
            ),
            processingState: .complete
        )
    }
}
