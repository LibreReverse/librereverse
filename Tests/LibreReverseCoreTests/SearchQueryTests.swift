#if os(macOS)
import XCTest
@testable import LibreReverseCore

final class SearchQueryTests: XCTestCase {
    func testCapturedSimpleAndPhraseBindings() {
        XCTAssertEqual(
            SearchQuery.matchExpression(for: "google"),
            "(\"google\")"
        )
        XCTAssertEqual(
            SearchQuery.matchExpression(for: "google drive"),
            "(\"google\" AND \"drive\")"
        )
        XCTAssertEqual(
            SearchQuery.matchExpression(for: "\"google drive\""),
            "(\"google drive\")"
        )
    }

    func testWhitespaceAndEmptyQuotedAtomsDoNotCreateFTSOperators() {
        XCTAssertNil(SearchQuery.matchExpression(for: " \n\t "))
        XCTAssertNil(SearchQuery.matchExpression(for: "\"\""))
        XCTAssertEqual(
            SearchQuery.matchExpression(for: "  google   \"drive sync\" "),
            "(\"google\" AND \"drive sync\")"
        )
    }

    func testOffsetParserConsumesFTS4QuadruplesInOrder() {
        XCTAssertEqual(
            SearchOffsetParser.parse(
                "0 2 6 5 1 0 0 4",
                primaryText: "hello world",
                otherText: "more text"
            ),
            [
                .init(column: .primaryText, term: 2, lowerBound: 6, upperBound: 11),
                .init(column: .otherText, term: 0, lowerBound: 0, upperBound: 4),
            ]
        )
    }

    func testOffsetParserCorrectsUTF8BytesToUTF16Coordinates() {
        XCTAssertEqual(
            SearchOffsetParser.parse(
                "0 0 5 2 0 1 8 4 1 2 0 6",
                primaryText: "A café 😀Z",
                otherText: "東京"
            ),
            [
                .init(column: .primaryText, term: 0, lowerBound: 5, upperBound: 6),
                .init(column: .primaryText, term: 1, lowerBound: 7, upperBound: 9),
                .init(column: .otherText, term: 2, lowerBound: 0, upperBound: 2),
            ]
        )
    }

    func testOffsetParserMatchesCompactMapAndCompleteGroupBehavior() {
        XCTAssertEqual(
            SearchOffsetParser.parse(
                "junk 0 3 0 5 7 9 11",
                primaryText: "hello",
                otherText: ""
            ),
            [.init(column: .primaryText, term: 3, lowerBound: 0, upperBound: 5)]
        )
        XCTAssertEqual(
            SearchOffsetParser.parse(
                "2 0 0 1 0 0 99 1",
                primaryText: "x",
                otherText: ""
            ),
            []
        )
    }

    func testFirstMatchOrderingUsesColumnThenCorrectedRangeStartOnly() {
        let parsed = SearchOffsetParser.parse(
            "1 0 0 2 0 4 6 1 0 3 1 1 0 2 1 1",
            primaryText: "abcdefgh",
            otherText: "xy"
        )
        XCTAssertEqual(
            SearchOffsetParser.orderedForFirstMatch(parsed),
            [
                .init(column: .primaryText, term: 3, lowerBound: 1, upperBound: 2),
                .init(column: .primaryText, term: 2, lowerBound: 1, upperBound: 2),
                .init(column: .primaryText, term: 4, lowerBound: 6, upperBound: 7),
                .init(column: .otherText, term: 0, lowerBound: 0, upperBound: 2),
            ]
        )
    }

    func testResultReducerUsesAcceptedTwentyResultLookback() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        let first = result(id: 1, instant: origin, title: "Repeated")
        let intervening = (2...21).map {
            result(id: Int64($0), instant: origin, title: "Unique \($0)")
        }
        let stillInsideLookback = result(
            id: 22,
            instant: origin.addingTimeInterval(1),
            title: "Unique 2"
        )
        let outsideLookback = result(
            id: 23,
            instant: origin.addingTimeInterval(1),
            title: "Repeated"
        )

        let reduced = SearchResultDeduplicator.reduce(
            [first] + intervening + [stillInsideLookback, outsideLookback]
        )
        XCTAssertFalse(reduced.contains { $0.candidate.docID == 22 })
        XCTAssertTrue(reduced.contains { $0.candidate.docID == 23 })
    }

    func testMatchRectangleSizeIsAnUnconditionalDuplicate() {
        let first = result(
            id: 1,
            instant: Date(timeIntervalSinceReferenceDate: 0),
            bundleID: "one",
            title: "one",
            type: .capturedScreen,
            rectangle: .init(width: 0.2, height: 0.1)
        )
        let second = result(
            id: 2,
            instant: Date(timeIntervalSinceReferenceDate: 10_000),
            bundleID: "two",
            title: "two",
            type: .audio,
            rectangle: .init(width: 0.205, height: 0.104)
        )
        XCTAssertEqual(
            SearchResultDeduplicator.reduce([first, second]).map(\.candidate.docID),
            [1]
        )
    }

    func testRectangleThresholdIsStrict() {
        let first = result(
            id: 1,
            instant: Date(timeIntervalSinceReferenceDate: 0),
            title: "one",
            rectangle: .init(width: 0, height: 0)
        )
        let exactlyThreshold = result(
            id: 2,
            instant: Date(timeIntervalSinceReferenceDate: 10_000),
            title: "two",
            rectangle: .init(width: 0.01, height: 0)
        )
        XCTAssertEqual(
            SearchResultDeduplicator.reduce([first, exactlyThreshold]).count,
            2
        )
    }

    func testContextComparatorRequiresEveryFieldAndUsesInclusiveFiveMinutes() {
        let base = result(
            id: 1,
            instant: Date(timeIntervalSinceReferenceDate: 1_000),
            bundleID: "com.example.App",
            title: "Draft",
            type: .capturedScreen,
            transcript: nil
        )
        let atBoundary = result(
            id: 2,
            instant: base.representativeInstant.addingTimeInterval(300),
            bundleID: "com.example.App",
            title: "Draft",
            type: .capturedScreen,
            transcript: nil
        )
        XCTAssertTrue(SearchResultDeduplicator.resultsAreEquivalent(base, atBoundary))

        let beyond = result(
            id: 3,
            instant: base.representativeInstant.addingTimeInterval(300.001),
            bundleID: "com.example.App",
            title: "Draft",
            type: .capturedScreen,
            transcript: nil
        )
        XCTAssertFalse(SearchResultDeduplicator.resultsAreEquivalent(base, beyond))

        let differentType = result(
            id: 4,
            instant: base.representativeInstant,
            bundleID: "com.example.App",
            title: "Draft",
            type: .importedScreenshot,
            transcript: nil
        )
        XCTAssertFalse(SearchResultDeduplicator.resultsAreEquivalent(base, differentType))
    }

    func testTranscriptDetailsParticipateInContextEquality() {
        let instant = Date(timeIntervalSinceReferenceDate: 1_000)
        let transcript = PopulatedSearchResult.TranscriptDetails(
            id: 7,
            transcript: "hello",
            matchInstant: instant
        )
        let first = result(
            id: 1, instant: instant, title: "Meeting", type: .audio,
            transcript: transcript
        )
        let second = result(
            id: 2, instant: instant, title: "Meeting", type: .audio,
            transcript: .init(id: 7, transcript: "different", matchInstant: instant)
        )
        XCTAssertFalse(SearchResultDeduplicator.resultsAreEquivalent(first, second))
    }

    private func result(
        id: Int64,
        instant: Date,
        bundleID: String? = "com.example.App",
        title: String,
        type: SegmentType = .capturedScreen,
        rectangle: PopulatedSearchResult.MatchRectangle? = nil,
        transcript: PopulatedSearchResult.TranscriptDetails? = nil
    ) -> PopulatedSearchResult {
        .init(
            candidate: .init(
                docID: id,
                frameID: id,
                segmentID: id,
                frameDate: instant,
                bundleID: bundleID,
                windowName: title,
                text: "",
                otherText: ""
            ),
            representativeInstant: instant,
            resolvedTitle: title,
            segmentType: type,
            matchRectangle: rectangle,
            transcriptDetails: transcript
        )
    }
}
#endif
