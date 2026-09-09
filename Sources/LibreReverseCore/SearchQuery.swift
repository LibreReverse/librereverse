#if os(macOS)
import Foundation

/// One row from the app's amplified recency query, before its separate
/// result-population and deduplication passes.
public struct HistoricalSearchCandidate: Equatable, Sendable {
    public let docID: Int64
    public let frameID: Int64?
    public let segmentID: Int64
    public let frameDate: Date?
    public let isStarred: Bool
    public let bundleID: String?
    public let windowName: String?
    public let browserURL: String?
    public let segmentType: SegmentType
    public let text: String
    public let otherText: String

    public init(
        docID: Int64,
        frameID: Int64?,
        segmentID: Int64,
        frameDate: Date?,
        isStarred: Bool = false,
        bundleID: String?,
        windowName: String?,
        browserURL: String? = nil,
        segmentType: SegmentType = .capturedScreen,
        text: String,
        otherText: String
    ) {
        self.docID = docID
        self.frameID = frameID
        self.segmentID = segmentID
        self.frameDate = frameDate
        self.isStarred = isStarred
        self.bundleID = bundleID
        self.windowName = windowName
        self.browserURL = browserURL
        self.segmentType = segmentType
        self.text = text
        self.otherText = otherText
    }
}

/// Facets consumed by the app's recency search query.
///
/// Application identifiers deliberately remain an ordered array. Runtime SQL
/// bindings preserve selection order both in the
/// generated `IN` placeholders and their bindings. Meetings is not a second
/// result kind at this layer: it substitutes the recorder's synthetic bundle
/// identifier and can still be combined with Starred.
public struct SearchFacets: Equatable, Sendable {
    public static let meetingRecorderBundleID = "ai.rewind.audiorecorder"

    public var applicationBundleIDs: [String]
    public var isStarred: Bool
    public var isTranscript: Bool

    public init(
        applicationBundleIDs: [String] = [],
        isStarred: Bool = false,
        isTranscript: Bool = false
    ) {
        self.applicationBundleIDs = Self.unique(applicationBundleIDs)
        self.isStarred = isStarred
        self.isTranscript = isTranscript
    }

    /// Exact bundle predicate represented by the app UI state.
    public var effectiveApplicationBundleIDs: [String] {
        isTranscript ? [Self.meetingRecorderBundleID] : applicationBundleIDs
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Exclusive descending keyset cursor used by recency search continuation.
public struct SearchRecencyCursor: Equatable, Sendable {
    public let documentID: Int64
    /// The recorded instant the previous page ended at.
    ///
    /// Document identifiers are monotonic only within each database. Imported
    /// shards and the primary database have independent identifier sequences,
    /// so library-wide paging orders by instant before the document ID.
    public let instant: Date?

    public init(documentID: Int64, instant: Date? = nil) {
        self.documentID = documentID
        self.instant = instant
    }
}

/// One row from the app app-facet count query.
public struct SearchApplicationCount: Equatable, Sendable {
    public let bundleID: String
    public let count: Int

    public init(bundleID: String, count: Int) {
        self.bundleID = bundleID
        self.count = count
    }
}

/// A populated visual Explorer result after FTS offset resolution and the
/// app's bounded result reduction.
public struct OCRSearchResult: Equatable, Sendable {
    public let result: PopulatedSearchResult
    public let firstNode: OCRNode

    public init(result: PopulatedSearchResult, firstNode: OCRNode) {
        self.result = result
        self.firstNode = firstNode
    }
}

/// One visible recency page after the 15x candidate amplification and
/// populated-result reduction used by Memory Explorer.
public struct OCRSearchPage: Equatable, Sendable {
    public let results: [OCRSearchResult]
    public let nextCursor: SearchRecencyCursor?
    public let hasMore: Bool
    /// FTS offsets for the documents this page resolved. Offsets are gathered
    /// per page rather than for the whole match set, so each page carries its
    /// own and the caller accumulates them for match presentation.
    public let offsetsByDocument: [Int64: String]

    public init(
        results: [OCRSearchResult],
        nextCursor: SearchRecencyCursor?,
        hasMore: Bool,
        offsetsByDocument: [Int64: String] = [:]
    ) {
        self.results = results
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.offsetsByDocument = offsetsByDocument
    }
}

/// A transcript-backed search result. It deliberately has no synthetic OCR
/// node or screenshot crop: the matching word and its reconstructed wall-clock
/// instant are carried by `transcriptDetails`.
public struct TranscriptSearchResult: Equatable, Sendable {
    public let result: PopulatedSearchResult

    public init(result: PopulatedSearchResult) {
        precondition(result.segmentType == .audio)
        precondition(result.transcriptDetails != nil)
        self.result = result
    }
}

public struct TranscriptSearchPage: Equatable, Sendable {
    public let results: [TranscriptSearchResult]
    public let nextCursor: SearchRecencyCursor?
    public let hasMore: Bool
    public let offsetsByDocument: [Int64: String]

    public init(
        results: [TranscriptSearchResult],
        nextCursor: SearchRecencyCursor?,
        hasMore: Bool,
        offsetsByDocument: [Int64: String]
    ) {
        self.results = results
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.offsetsByDocument = offsetsByDocument
    }
}

/// One modern FTS match range after the app has resolved offsets.
/// Bounds are UTF-16 offsets and remain half-open at the model boundary. The
/// node lookup intentionally uses the upper bound in an inclusive overlap
/// comparison, matching the app SQL exactly.
public struct SearchQueryOffset: Equatable, Sendable {
    public enum Column: Equatable, Sendable {
        case primaryText
        case otherText
    }

    public let column: Column
    public let term: Int
    public let lowerBound: Int
    public let upperBound: Int

    public init(
        column: Column,
        term: Int,
        lowerBound: Int,
        upperBound: Int
    ) {
        precondition(lowerBound >= 0 && upperBound >= lowerBound)
        self.column = column
        self.term = term
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// Parses the quadruples emitted by SQLite FTS4's `offsets()` function.
///
/// Parsing splits on
/// spaces, compact-maps base-10 integers, and consumes complete groups of four:
/// column, query-term index, UTF-8 byte offset, and UTF-8 byte length. Explorer
/// invokes it with UTF-16 correction enabled because persisted OCR nodes use
/// Swift/NSString-compatible UTF-16 coordinates.
public enum SearchOffsetParser {
    public static func parse(
        _ offsetString: String,
        primaryText: String,
        otherText: String
    ) -> [SearchQueryOffset] {
        let values = offsetString
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap { Int($0, radix: 10) }
        let columns = [primaryText, otherText]
        var result: [SearchQueryOffset] = []
        result.reserveCapacity(values.count / 4)

        var index = 0
        while index + 3 < values.count {
            let columnIndex = values[index]
            let term = values[index + 1]
            let byteOffset = values[index + 2]
            let byteLength = values[index + 3]
            index += 4

            guard columns.indices.contains(columnIndex),
                  byteOffset >= 0,
                  byteLength >= 0,
                  let range = utf16Range(
                    byteOffset: byteOffset,
                    byteLength: byteLength,
                    in: columns[columnIndex]
                  ) else {
                continue
            }
            result.append(SearchQueryOffset(
                column: columnIndex == 0 ? .primaryText : .otherText,
                term: term,
                lowerBound: range.lowerBound,
                upperBound: range.upperBound
            ))
        }
        return result
    }

    /// The specialized sort invoked by `firstMatch` orders only by column and
    /// corrected range start. Term number and range end are not tie breakers.
    public static func orderedForFirstMatch(
        _ offsets: [SearchQueryOffset]
    ) -> [SearchQueryOffset] {
        offsets.sorted { lhs, rhs in
            let lhsColumn = lhs.column == .primaryText ? 0 : 1
            let rhsColumn = rhs.column == .primaryText ? 0 : 1
            if lhsColumn != rhsColumn { return lhsColumn < rhsColumn }
            return lhs.lowerBound < rhs.lowerBound
        }
    }

    private static func utf16Range(
        byteOffset: Int,
        byteLength: Int,
        in text: String
    ) -> Range<Int>? {
        guard byteOffset <= text.utf8.count,
              byteLength <= text.utf8.count - byteOffset else {
            return nil
        }
        let utf8Start = text.utf8.index(text.utf8.startIndex, offsetBy: byteOffset)
        let utf8End = text.utf8.index(utf8Start, offsetBy: byteLength)
        guard let utf16Start = utf8Start.samePosition(in: text.utf16),
              let utf16End = utf8End.samePosition(in: text.utf16) else {
            return nil
        }
        let lowerBound = text.utf16.distance(
            from: text.utf16.startIndex,
            to: utf16Start
        )
        let upperBound = text.utf16.distance(
            from: text.utf16.startIndex,
            to: utf16End
        )
        return lowerBound..<upperBound
    }
}

/// Populated search result consumed by deduplication and presentation. Resolve
/// the representative date, title, OCR match, and transcript details before
/// reducing candidates so duplicate raw search rows do not become UI cards.
public struct PopulatedSearchResult: Equatable, Sendable {
    public struct MatchRectangle: Equatable, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct TranscriptDetails: Equatable, Sendable {
        public let id: Int64
        public let transcript: String
        public let matchInstant: Date

        public init(id: Int64, transcript: String, matchInstant: Date) {
            self.id = id
            self.transcript = transcript
            self.matchInstant = matchInstant
        }
    }

    public let candidate: HistoricalSearchCandidate
    public let representativeInstant: Date
    public let resolvedTitle: String
    public let segmentType: SegmentType
    public let matchRectangle: MatchRectangle?
    public let transcriptDetails: TranscriptDetails?

    public init(
        candidate: HistoricalSearchCandidate,
        representativeInstant: Date,
        resolvedTitle: String,
        segmentType: SegmentType,
        matchRectangle: MatchRectangle?,
        transcriptDetails: TranscriptDetails? = nil
    ) {
        self.candidate = candidate
        self.representativeInstant = representativeInstant
        self.resolvedTitle = resolvedTitle
        self.segmentType = segmentType
        self.matchRectangle = matchRectangle
        self.transcriptDetails = transcriptDetails
    }
}

/// Bounded deduplication of populated recency results.
///
/// For each populated result, only the most recent `lookback` accepted results
/// are tested. A nearly identical match-box size is an unconditional duplicate;
/// otherwise `Database.SearchResult` applies its segment/context/time equality.
public enum SearchResultDeduplicator {
    public static let defaultLookback = 20
    public static let matchRectangleSizeThreshold = 0.01
    public static let equivalentResultTimeWindow: TimeInterval = 300

    public static func reduce(
        _ input: [PopulatedSearchResult],
        lookback: Int = defaultLookback
    ) -> [PopulatedSearchResult] {
        precondition(lookback >= 0)
        var accepted: [PopulatedSearchResult] = []
        accepted.reserveCapacity(input.count)

        for result in input {
            let prior = lookback == 0
                ? accepted[accepted.endIndex..<accepted.endIndex]
                : accepted.suffix(lookback)
            let duplicate = prior.contains { previous in
                rectanglesHaveEquivalentSize(result, previous)
                    || resultsAreEquivalent(result, previous)
            }
            if !duplicate { accepted.append(result) }
        }
        return accepted
    }

    public static func rectanglesHaveEquivalentSize(
        _ lhs: PopulatedSearchResult,
        _ rhs: PopulatedSearchResult
    ) -> Bool {
        guard let lhs = lhs.matchRectangle, let rhs = rhs.matchRectangle else {
            return false
        }
        return abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
            < matchRectangleSizeThreshold
    }

    public static func resultsAreEquivalent(
        _ lhs: PopulatedSearchResult,
        _ rhs: PopulatedSearchResult
    ) -> Bool {
        lhs.candidate.bundleID == rhs.candidate.bundleID
            && lhs.resolvedTitle == rhs.resolvedTitle
            && lhs.segmentType == rhs.segmentType
            && lhs.transcriptDetails == rhs.transcriptDetails
            && abs(lhs.representativeInstant.timeIntervalSince(rhs.representativeInstant))
                <= equivalentResultTimeWindow
    }
}

/// Normalizes user search terms into an FTS match expression.
///
/// The app does not expose FTS Boolean syntax. Unquoted lexical terms
/// become quoted FTS atoms joined by AND; a user-quoted phrase remains one
/// quoted atom. Each bound expression is enclosed in parentheses.
public enum SearchQuery {
    public static func matchExpression(for query: String) -> String? {
        let atoms = atoms(in: query)
        guard !atoms.isEmpty else { return nil }
        return "(" + atoms.map { "\"\(escapeFTSString($0))\"" }
            .joined(separator: " AND ") + ")"
    }

    private static func atoms(in query: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false

        func finish() {
            let atom = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !atom.isEmpty { result.append(atom) }
            current.removeAll(keepingCapacity: true)
        }

        for character in query {
            if character == "\"" {
                if quoted {
                    finish()
                    quoted = false
                } else {
                    finish()
                    quoted = true
                }
            } else if character.isWhitespace, !quoted {
                finish()
            } else {
                current.append(character)
            }
        }
        finish()
        return result
    }

    private static func escapeFTSString(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
#endif
