#if os(macOS)
import CSQLCipher
import Foundation

public struct LibraryDatabaseConfiguration: Sendable {
    public let databaseURL: URL
    public let keyFileURL: URL
    public let mediaRoot: URL
    public let frameImagesRoot: URL

    public init(
        databaseURL: URL,
        keyFileURL: URL,
        mediaRoot: URL,
        frameImagesRoot: URL? = nil
    ) {
        self.databaseURL = databaseURL
        self.keyFileURL = keyFileURL
        self.mediaRoot = mediaRoot
        // Deferred capture images live inside the native media directory.
        self.frameImagesRoot = frameImagesRoot
            ?? mediaRoot.appendingPathComponent("temp", isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
    }
}

public struct HistoricalTimelineMoment: Equatable, Sendable {
    public let frameID: Int64
    public let wallDate: Date
    public let databaseVideoID: Int64?
    public let chunkURL: URL?
    public let frameImageURL: URL
    public let mediaTime: TimeInterval?
    public let videoFrameIndex: Int?
    public let videoFrameRate: Double?
    public let videoWidth: Int
    public let videoHeight: Int
    public let segmentID: Int64?
    public let bundleID: String?
    public let segmentStartDate: Date?
    public let segmentEndDate: Date?
    public let windowName: String?
    public let browserURL: String?
    public let segmentType: Int?
    public let isStarred: Bool
    public let isPendingImage: Bool

    public init(
        frameID: Int64,
        wallDate: Date,
        databaseVideoID: Int64?,
        chunkURL: URL?,
        frameImageURL: URL,
        mediaTime: TimeInterval?,
        videoFrameIndex: Int?,
        videoFrameRate: Double?,
        videoWidth: Int,
        videoHeight: Int,
        segmentID: Int64?,
        bundleID: String?,
        segmentStartDate: Date?,
        segmentEndDate: Date?,
        windowName: String?,
        browserURL: String?,
        segmentType: Int?,
        isStarred: Bool,
        isPendingImage: Bool
    ) {
        self.frameID = frameID
        self.wallDate = wallDate
        self.databaseVideoID = databaseVideoID
        self.chunkURL = chunkURL
        self.frameImageURL = frameImageURL
        self.mediaTime = mediaTime
        self.videoFrameIndex = videoFrameIndex
        self.videoFrameRate = videoFrameRate
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.segmentID = segmentID
        self.bundleID = bundleID
        self.segmentStartDate = segmentStartDate
        self.segmentEndDate = segmentEndDate
        self.windowName = windowName
        self.browserURL = browserURL
        self.segmentType = segmentType
        self.isStarred = isStarred
        self.isPendingImage = isPendingImage
    }
}

public struct LibreReverseMeetingTranscriptWord: Equatable, Sendable {
    public let id: Int64
    public let speechSource: String
    public let text: String
    public let startSeconds: TimeInterval
    public let durationSeconds: TimeInterval
    public let fullTextUTF16Offset: Int?

    public var endSeconds: TimeInterval { startSeconds + durationSeconds }

    public init(
        id: Int64,
        speechSource: String,
        text: String,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        fullTextUTF16Offset: Int?
    ) {
        self.id = id
        self.speechSource = speechSource
        self.text = text
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.fullTextUTF16Offset = fullTextUTF16Offset
    }
}

/// Presentation labels for persisted transcript speakers. Unknown sources stay
/// unlabeled, and display normalization never changes persisted or exported text.
public enum LibreReverseMeetingSpeechSourceKind: String, Equatable, Sendable {
    case me
    case others
    case unknown

    public init(persistedValue: String) {
        switch persistedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "me", "microphone": self = .me
        case "others", "system": self = .others
        default: self = .unknown
        }
    }

    public var displayName: String? {
        switch self {
        case .me: "You"
        case .others: "Others"
        case .unknown: nil
        }
    }
}

public struct LibreReverseMeetingTranscriptMetadata: Equatable, Sendable {
    public let provider: LibreReverseMeetingProvider?
    public let source: LibreReverseMeetingCandidateSource?
    public let calendarTitle: String?
    public let participants: [String]
    public let calendarID: String?
    public let calendarEventID: String?
    public let calendarSeriesID: String?

    public init(
        provider: LibreReverseMeetingProvider? = nil,
        source: LibreReverseMeetingCandidateSource? = nil,
        calendarTitle: String? = nil,
        participants: [String] = [],
        calendarID: String? = nil,
        calendarEventID: String? = nil,
        calendarSeriesID: String? = nil
    ) {
        self.provider = provider
        self.source = source
        self.calendarTitle = calendarTitle
        self.participants = participants
        self.calendarID = calendarID
        self.calendarEventID = calendarEventID
        self.calendarSeriesID = calendarSeriesID
    }

    public var compactLabels: [String] {
        var labels: [String] = []
        if let provider, provider != .manual, provider != .calendar {
            labels.append(provider.displayName)
        }
        if let calendarTitle = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !calendarTitle.isEmpty
        {
            labels.append(calendarTitle)
        }
        if !participants.isEmpty {
            labels.append(
                participants.count == 1 ? "1 participant" : "\(participants.count) participants"
            )
        }
        return labels
    }

    public func updating(_ context: LibreReverseMeetingContextUpdate) -> Self {
        .init(
            provider: provider,
            source: source,
            calendarTitle: context.calendarTitle,
            participants: context.participants,
            calendarID: calendarID,
            calendarEventID: calendarEventID,
            calendarSeriesID: calendarSeriesID
        )
    }
}

/// Runtime presentation state for a meeting transcript. Only `.complete` is
/// inferred from persisted transcript rows; queue-backed states are overlaid
/// by the app without changing the persisted recording graph.
public enum LibreReverseMeetingTranscriptProcessingState: Equatable, Sendable {
    case unavailable
    case queued
    case retrying(attempt: Int, retryAfter: Date?)
    case complete

    public var emptyStateDescription: String {
        switch self {
        case .unavailable: "No transcript available"
        case .queued: "Transcribing…"
        case .retrying: "Transcription will retry"
        case .complete: "No speech detected"
        }
    }
}

public struct LibreReverseMeetingTranscript: Equatable, Sendable {
    public let segmentID: Int64
    public let title: String
    public let text: String
    public let startDate: Date
    public let endDate: Date
    public let words: [LibreReverseMeetingTranscriptWord]
    public let metadata: LibreReverseMeetingTranscriptMetadata
    public let processingState: LibreReverseMeetingTranscriptProcessingState

    public var hasTranscriptText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Known sources in first-appearance order. Combined recordings persisted
    /// as `unknown` produce no legend rather than a fabricated speaker label.
    public var presentedSpeechSources: [LibreReverseMeetingSpeechSourceKind] {
        var seen = Set<LibreReverseMeetingSpeechSourceKind>()
        return words.compactMap { word in
            let source = LibreReverseMeetingSpeechSourceKind(
                persistedValue: word.speechSource
            )
            guard source != .unknown, seen.insert(source).inserted else { return nil }
            return source
        }
    }

    public init(
        segmentID: Int64,
        title: String,
        text: String,
        startDate: Date,
        endDate: Date,
        words: [LibreReverseMeetingTranscriptWord],
        metadata: LibreReverseMeetingTranscriptMetadata = .init(),
        processingState: LibreReverseMeetingTranscriptProcessingState = .unavailable
    ) {
        self.segmentID = segmentID
        self.title = title
        self.text = text
        self.startDate = startDate
        self.endDate = endDate
        self.words = words
        self.metadata = metadata
        self.processingState = processingState
    }

    public func activeWordIndex(at wallDate: Date) -> Int? {
        guard !words.isEmpty else { return nil }
        let elapsed = max(0, wallDate.timeIntervalSince(startDate))
        if let containing = words.lastIndex(where: {
            $0.startSeconds <= elapsed && elapsed < max($0.endSeconds, $0.startSeconds + 1)
        }) {
            return containing
        }
        return words.lastIndex(where: { $0.startSeconds <= elapsed })
    }

    public func wallDate(forWordAt index: Int) -> Date? {
        guard words.indices.contains(index) else { return nil }
        return startDate.addingTimeInterval(words[index].startSeconds)
    }

    public func updatingTitle(_ title: String) -> Self {
        .init(
            segmentID: segmentID,
            title: title,
            text: text,
            startDate: startDate,
            endDate: endDate,
            words: words,
            metadata: metadata,
            processingState: processingState
        )
    }

    public func updatingContext(_ context: LibreReverseMeetingContextUpdate) -> Self {
        .init(
            segmentID: segmentID,
            title: title,
            text: text,
            startDate: startDate,
            endDate: endDate,
            words: words,
            metadata: metadata.updating(context),
            processingState: processingState
        )
    }

    public func updatingProcessingState(
        _ processingState: LibreReverseMeetingTranscriptProcessingState
    ) -> Self {
        .init(
            segmentID: segmentID,
            title: title,
            text: text,
            startDate: startDate,
            endDate: endDate,
            words: words,
            metadata: metadata,
            processingState: processingState
        )
    }
}

/// The bounded row set used by the explorer and its independent global
/// seekable wall-date interval. `validSeekInterval` must not be derived
/// from the currently loaded `segments`.
public struct HistoricalTimelineSegmentWindow: Equatable, Sendable {
    public let playbackFrameDates: [Date]?
    public let segments: [TimelineSegment]
    public let validSeekInterval: DateInterval?

    public init(
        segments: [TimelineSegment],
        validSeekInterval: DateInterval?,
        playbackFrameDates: [Date]? = nil
    ) {
        self.playbackFrameDates = playbackFrameDates
        self.segments = segments
        self.validSeekInterval = validSeekInterval
    }
}

public enum LibraryDatabaseError: Error, Equatable {
    case keyFileIsNotPrivate
    case invalidKeyLength
    case unableToOpenDatabase(String)
    case unableToApplyKey(Int32)
    case unsupportedSchemaVersion(Int)
    case queryFailed(String)
    case invalidDate(String)
    case shardUnavailable(ordinal: Int64, state: String)
}

public enum LibraryDatabase {
    public static let initialTimelineWindowDuration: TimeInterval = 600

    public static func recordingInterval(configuration: LibraryDatabaseConfiguration) throws -> DateInterval? {
        try withDatabase(configuration: configuration) { database in
            try globalTimelineInterval(database: database)
        }
    }

    public static func loadTimelineWindow(
        around date: Date,
        duration: TimeInterval,
        configuration: LibraryDatabaseConfiguration
    ) throws -> HistoricalTimelineSegmentWindow {
        try withDatabase(configuration: configuration) { database in
            try loadTimelineWindow(database: database, around: date, duration: duration)
        }
    }

    public static func loadRecentTimelineWindow(
        duration: TimeInterval = initialTimelineWindowDuration,
        configuration: LibraryDatabaseConfiguration
    ) throws -> HistoricalTimelineSegmentWindow {
        try withDatabase(configuration: configuration) { database in
            try loadRecentTimelineWindow(database: database, duration: duration)
        }
    }

    /// Loads starred-frame wall dates without imposing order. Callers decide how
    /// to project and order markers in their timeline presentation.
    public static func loadStarredFrameDates(
        configuration: LibraryDatabaseConfiguration
    ) throws -> [Date] {
        try withDatabase(configuration: configuration) { database in
            try query(database: database, sql: starredFrameDatesSQL) { statement in
                try databaseDate(string(statement, column: 0) ?? "")
            }
        }
    }

    static let starredFrameDatesSQL = """
        SELECT createdAt
          FROM frame
         WHERE isStarred = 1
        """

    /// Decodes one bounded Segment pager row. Unknown `type` values are skipped.
    static func decodeSegment(_ statement: OpaquePointer) throws -> TimelineSegment? {
        let rawType = Int(sqlite3_column_int64(statement, 7))
        guard let type = SegmentType(rawValue: rawType) else { return nil }
        return TimelineSegment(
            startDate: try databaseDate(string(statement, column: 1) ?? ""),
            endDate: try databaseDate(string(statement, column: 2) ?? ""),
            bundleID: string(statement, column: 3),
            windowName: string(statement, column: 4),
            browserURL: string(statement, column: 5),
            browserProfile: string(statement, column: 6),
            rawID: sqlite3_column_int64(statement, 0),
            rawType: type
        )
    }

    static func loadTimelineWindow(
        database: OpaquePointer,
        around date: Date,
        duration: TimeInterval
    ) throws -> HistoricalTimelineSegmentWindow {
        let halfDuration = duration * 0.5
        // A failed read must not be published as an empty history window.
        let before = try pageTimelineSegments(
            database: database, anchor: date, direction: .before, duration: halfDuration)
        let after = try pageTimelineSegments(
            database: database, anchor: date, direction: .after, duration: halfDuration)
        let segments = before + after
        return HistoricalTimelineSegmentWindow(
            segments: segments,
            validSeekInterval: try globalTimelineInterval(database: database)
        )
    }

    static func loadRecentTimelineWindow(
        database: OpaquePointer,
        duration: TimeInterval
    ) throws -> HistoricalTimelineSegmentWindow {
        let segments = try pageTimelineSegments(
            database: database, anchor: nil, direction: .before, duration: duration)
        return HistoricalTimelineSegmentWindow(
            segments: segments,
            validSeekInterval: try globalTimelineInterval(database: database)
        )
    }

    private enum TimelinePageDirection {
        case before
        case after
    }

    /// Exact 100-row duration pager used by the canonical Database methods.
    /// The page which crosses the duration threshold is retained in full.
    private static func pageTimelineSegments(
        database: OpaquePointer,
        anchor: Date?,
        direction: TimelinePageDirection,
        duration: TimeInterval
    ) throws -> [TimelineSegment] {
        guard duration > 0 else { return [] }
        var cursor: (date: Date, id: Int64)?
        var result: [TimelineSegment] = []
        var accumulatedDuration: TimeInterval = 0

        while true {
            let sql: String
            switch (direction, anchor, cursor) {
            case (.before, .some, nil):
                sql =
                    boundedSegmentSelect
                    + " WHERE startDate <= ? ORDER BY startDate DESC, id DESC LIMIT 100"
            case (.before, nil, nil):
                sql = boundedSegmentSelect + " ORDER BY startDate DESC, id DESC LIMIT 100"
            case (.before, _, .some):
                sql =
                    boundedSegmentSelect
                    + " WHERE (startDate < ? OR (startDate = ? AND id < ?)) ORDER BY startDate DESC, id DESC LIMIT 100"
            case (.after, .some, nil):
                sql =
                    boundedSegmentSelect
                    + " WHERE startDate > ? ORDER BY startDate ASC, id ASC LIMIT 100"
            case (.after, nil, nil):
                preconditionFailure("after pager requires an anchor")
            case (.after, _, .some):
                sql =
                    boundedSegmentSelect
                    + " WHERE (startDate > ? OR (startDate = ? AND id > ?)) ORDER BY startDate ASC, id ASC LIMIT 100"
            }

            let (page, rawRowCount, lastRawCursor) = try queryTimelinePage(
                database: database,
                sql: sql,
                anchor: anchor,
                cursor: cursor
            )
            result.append(contentsOf: page)
            accumulatedDuration += page.reduce(0) {
                $0 + $1.endDate.timeIntervalSince($1.startDate)
            }
            guard rawRowCount == 100,
                accumulatedDuration < duration,
                let lastRawCursor
            else { break }
            cursor = lastRawCursor
        }
        if case .before = direction { result.reverse() }
        return result
    }

    private static func queryTimelinePage(
        database: OpaquePointer,
        sql: String,
        anchor: Date?,
        cursor: (date: Date, id: Int64)?
    ) throws -> ([TimelineSegment], Int, (Date, Int64)?) {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &raw, nil) == SQLITE_OK,
            let statement = raw
        else {
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let cursor {
            let value = databaseString(cursor.date)
            sqlite3_bind_text(statement, 1, value, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            sqlite3_bind_int64(statement, 3, cursor.id)
        } else if let anchor {
            sqlite3_bind_text(statement, 1, databaseString(anchor), -1, transient)
        }

        var page: [TimelineSegment] = []
        var rawRowCount = 0
        var lastRawCursor: (Date, Int64)?
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(errorMessage(database))
            }
            rawRowCount += 1
            let rowDate = try databaseDate(string(statement, column: 1) ?? "")
            lastRawCursor = (rowDate, sqlite3_column_int64(statement, 0))
            if let segment = try decodeSegment(statement) { page.append(segment) }
        }
        return (page, rawRowCount, lastRawCursor)
    }

    private static let boundedSegmentSelect = """
        SELECT id, startDate, endDate, bundleID, windowName,
               browserUrl, browserProfile, type
          FROM segment
        """

    /// Global wall-date bounds are min(segment.startDate) and max(segment.endDate).
    /// Use separate single-aggregate queries so SQLite can read each covering
    /// index; combining aggregates over different columns forces a table scan.
    static func globalTimelineInterval(database: OpaquePointer) throws -> DateInterval? {
        guard
            let startValue = try scalarText(
                database: database, sql: "SELECT min(startDate) FROM segment"
            )
        else { return nil }
        guard
            let endValue = try scalarText(
                database: database, sql: "SELECT max(endDate) FROM segment"
            )
        else { return nil }
        return DateInterval(
            start: try databaseDate(startValue),
            end: try databaseDate(endValue)
        )
    }

    /// Steps one row and returns its first column as text, or nil when the
    /// aggregate is NULL (empty table).
    private static func scalarText(
        database: OpaquePointer,
        sql: String
    ) throws -> String? {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &raw, nil) == SQLITE_OK,
            let statement = raw
        else {
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        return string(statement, column: 0)
    }

    public static func loadChunks(
        configuration: LibraryDatabaseConfiguration
    ) throws -> [TimelineChunk] {
        try withDatabase(configuration: configuration) { database in
            let sql = """
                SELECT v.id, v.path, v.width, v.height, v.frameRate,
                       count(f.id), min(f.createdAt), max(f.createdAt),
                       (SELECT s.bundleID
                          FROM frame firstFrame
                          LEFT JOIN segment s ON s.id = firstFrame.segmentId
                         WHERE firstFrame.videoId = v.id
                         ORDER BY firstFrame.videoFrameIndex, firstFrame.id
                         LIMIT 1)
                  FROM video v
                  JOIN frame f ON f.videoId = v.id
                 WHERE v.path <> '' AND f.videoFrameIndex IS NOT NULL
                 GROUP BY v.id, v.path, v.width, v.height, v.frameRate
                 ORDER BY min(f.createdAt), v.id
                """
            return try query(database: database, sql: sql) { statement in
                let videoID = sqlite3_column_int64(statement, 0)
                let path = string(statement, column: 1) ?? ""
                let width = Int(sqlite3_column_int64(statement, 2))
                let height = Int(sqlite3_column_int64(statement, 3))
                let frameRate = sqlite3_column_double(statement, 4)
                let sampleCount = Int(sqlite3_column_int64(statement, 5))
                let firstValue = string(statement, column: 6) ?? ""
                let lastValue = string(statement, column: 7) ?? ""
                let firstDate = try databaseDate(firstValue)
                let lastDate = try databaseDate(lastValue)
                let url = configuration.mediaRoot.appendingPathComponent(path)
                return TimelineChunk(
                    url: url,
                    startDate: firstDate,
                    wallEndDate: lastDate,
                    duration: frameRate > 0 ? TimeInterval(sampleCount) / frameRate : 0,
                    width: width,
                    height: height,
                    source: .historical,
                    samples: nil,
                    databaseVideoID: videoID,
                    sampleCount: sampleCount,
                    startingApplicationBundleID: string(statement, column: 8)
                )
            }
        }
    }

    public static func nearestMoment(
        to date: Date,
        configuration: LibraryDatabaseConfiguration
    ) throws -> HistoricalTimelineMoment? {
        try withDatabase(configuration: configuration) { database in
            func candidate(sql: String) throws -> HistoricalTimelineMoment? {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                    let statement
                else {
                    throw LibraryDatabaseError.queryFailed(errorMessage(database))
                }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, databaseString(date), -1, transient)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return nil }
                guard status == SQLITE_ROW else {
                    throw LibraryDatabaseError.queryFailed(errorMessage(database))
                }
                return try decodeMoment(statement, configuration: configuration)
            }

            let before = try candidate(sql: momentAtOrBeforeSQL)
            if before?.wallDate == date { return before }
            let after = try candidate(sql: momentAfterSQL)
            switch (before, after) {
            case (nil, let after?): return after
            case (let before?, nil): return before
            case (nil, nil): return nil
            case (let before?, let after?):
                let beforeDistance = abs(date.timeIntervalSince(before.wallDate))
                let afterDistance = abs(date.timeIntervalSince(after.wallDate))
                return beforeDistance < afterDistance ? before : after
            }
        }
    }

    private static func withDatabase<T>(
        configuration: LibraryDatabaseConfiguration,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let database = try openKeyedDatabase(configuration: configuration)
        defer { sqlite3_close(database) }
        return try operation(database)
    }

    /// Opens, keys, and version-checks a connection.
    ///
    /// SQLCipher derives its page key on first use, which is expensive.
    /// Per-interaction queries must reuse the opened connection.
    static func openKeyedDatabase(
        configuration: LibraryDatabaseConfiguration
    ) throws -> OpaquePointer {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: configuration.keyFileURL.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else {
            throw LibraryDatabaseError.keyFileIsNotPrivate
        }
        let key = try Data(contentsOf: configuration.keyFileURL)
        guard !key.isEmpty, key.count <= 4096 else {
            throw LibraryDatabaseError.invalidKeyLength
        }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            configuration.databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map(errorMessage) ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LibraryDatabaseError.unableToOpenDatabase(message)
        }
        var opened = true
        defer { if !opened { sqlite3_close(database) } }
        let keyStatus = key.withUnsafeBytes { bytes in
            sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
        }
        guard keyStatus == SQLITE_OK else {
            opened = false
            throw LibraryDatabaseError.unableToApplyKey(keyStatus)
        }
        // Readers share the live recording database with short write transactions.
        sqlite3_busy_timeout(database, 5_000)
        var versionStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil)
                == SQLITE_OK,
            let versionStatement
        else {
            opened = false
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        defer { sqlite3_finalize(versionStatement) }
        guard sqlite3_step(versionStatement) == SQLITE_ROW else {
            opened = false
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        let version = Int(sqlite3_column_int(versionStatement, 0))
        guard version == 41 else {
            opened = false
            throw LibraryDatabaseError.unsupportedSchemaVersion(version)
        }
        return database
    }

    static let momentAtOrBeforeSQL = """
        SELECT f.createdAt, f.videoFrameIndex, v.path, v.width, v.height, v.frameRate,
               s.id, s.bundleID, s.startDate, s.endDate, s.windowName, s.browserUrl,
               s.type, f.isStarred, f.imageFileName,
               CASE WHEN f.videoId IS NULL THEN 1 ELSE 0 END AS isDeferredImage,
               v.id, f.id
          FROM frame f
          LEFT JOIN video v ON v.id = f.videoId
          LEFT JOIN segment s ON s.id = f.segmentId
         WHERE f.createdAt <= ?
         ORDER BY f.createdAt DESC
         LIMIT 1
        """

    static let momentAfterSQL = """
        SELECT f.createdAt, f.videoFrameIndex, v.path, v.width, v.height, v.frameRate,
               s.id, s.bundleID, s.startDate, s.endDate, s.windowName, s.browserUrl,
               s.type, f.isStarred, f.imageFileName,
               CASE WHEN f.videoId IS NULL THEN 1 ELSE 0 END AS isDeferredImage,
               v.id, f.id
          FROM frame f
          LEFT JOIN video v ON v.id = f.videoId
          LEFT JOIN segment s ON s.id = f.segmentId
         WHERE f.createdAt > ?
         ORDER BY f.createdAt ASC
         LIMIT 1
        """

    static let meetingMomentSQL = """
        SELECT f.createdAt, f.videoFrameIndex, v.path, v.width, v.height, v.frameRate,
               s.id, s.bundleID, s.startDate, s.endDate, s.windowName, s.browserUrl,
               s.type, f.isStarred, f.imageFileName,
               CASE WHEN f.videoId IS NULL THEN 1 ELSE 0 END AS isDeferredImage,
               v.id, f.id
          FROM segment s
          JOIN frame f ON f.segmentId=s.id
          LEFT JOIN video v ON v.id=f.videoId
         WHERE s.id=? AND s.type=1
         ORDER BY f.createdAt,f.id
         LIMIT 1
        """

    /// Decodes one nearest-moment candidate row.
    static func decodeMoment(
        _ statement: OpaquePointer,
        configuration: LibraryDatabaseConfiguration
    ) throws -> HistoricalTimelineMoment {
        let wallDate = try databaseDate(string(statement, column: 0) ?? "")
        let frameIndex = optionalInt(statement, column: 1)
        let path = string(statement, column: 2)
        let frameRate =
            sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 5)
        let imageFileName = string(statement, column: 14) ?? ""
        let isPendingImage = sqlite3_column_int(statement, 15) != 0
        return HistoricalTimelineMoment(
            frameID: sqlite3_column_int64(statement, 17),
            wallDate: wallDate,
            databaseVideoID: optionalInt64(statement, column: 16),
            chunkURL: path.map(configuration.mediaRoot.appendingPathComponent),
            frameImageURL: configuration.frameImagesRoot
                .appendingPathComponent(imageFileName),
            mediaTime: frameIndex.flatMap { frameIndex in
                frameRate.flatMap { $0 > 0 ? TimeInterval(frameIndex) / $0 : nil }
            },
            videoFrameIndex: frameIndex,
            videoFrameRate: frameRate,
            videoWidth: Int(sqlite3_column_int64(statement, 3)),
            videoHeight: Int(sqlite3_column_int64(statement, 4)),
            segmentID: optionalInt64(statement, column: 6),
            bundleID: string(statement, column: 7),
            segmentStartDate: try optionalDatabaseDate(string(statement, column: 8)),
            segmentEndDate: try optionalDatabaseDate(string(statement, column: 9)),
            windowName: string(statement, column: 10),
            browserURL: string(statement, column: 11),
            segmentType: optionalInt(statement, column: 12),
            isStarred: sqlite3_column_int(statement, 13) != 0,
            isPendingImage: isPendingImage
        )
    }

    static func query<T>(
        database: OpaquePointer,
        sql: String,
        row: (OpaquePointer) throws -> T?
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw LibraryDatabaseError.queryFailed(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(errorMessage(database))
            }
            if let value = try row(statement) { values.append(value) }
        }
    }

    static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: text)
    }

    static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, column)
    }

    static func optionalInt(_ statement: OpaquePointer, column: Int32) -> Int? {
        optionalInt64(statement, column: column).map(Int.init)
    }

    static func databaseDate(_ value: String) throws -> Date {
        if let date = canonicalDatabaseDate(value) { return date }
        guard let date = databaseFormatter.date(from: value) else {
            throw LibraryDatabaseError.invalidDate(value)
        }
        return date
    }

    /// The canonical UTC representation is fixed-width. Avoid ICU parsing for
    /// every row while scrolling; preserve the formatter for legacy spellings.
    static func canonicalDatabaseDate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 23, bytes[4] == 45, bytes[7] == 45,
            bytes[10] == 84, bytes[13] == 58, bytes[16] == 58, bytes[19] == 46
        else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            var result = 0
            for index in start..<(start + count) {
                let digit = bytes[index]
                guard digit >= 48, digit <= 57 else { return nil }
                result = result * 10 + Int(digit - 48)
            }
            return result
        }
        guard let year = number(0, 4), year >= 1900,
            let month = number(5, 2), (1...12).contains(month),
            let day = number(8, 2), day >= 1,
            let hour = number(11, 2), hour < 24,
            let minute = number(14, 2), minute < 60,
            let second = number(17, 2), second < 60,
            let milliseconds = number(20, 3)
        else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthLengths[month - 1] else { return nil }
        // Gregorian civil date to days since 1970-01-01; March starts each year.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + hour * 3600 + minute * 60 + second)
            + Double(milliseconds) / 1000)
    }

    static func optionalDatabaseDate(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        return try databaseDate(value)
    }

    static func databaseString(_ date: Date) -> String {
        databaseFormatter.string(from: date)
    }

    /// Cache the formatter so parsing each segment date during scrubbing
    /// does not allocate a new formatter.
    static let databaseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}
#endif
