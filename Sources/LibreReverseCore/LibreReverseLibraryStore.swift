#if os(macOS)
import CSQLCipher
import Foundation

public struct LibreReverseRecordedFrame: Equatable, Sendable {
    public let frameID: Int64
    public let videoFrameIndex: Int

    public init(
        frameID: Int64,
        videoFrameIndex: Int
    ) {
        self.frameID = frameID
        self.videoFrameIndex = videoFrameIndex
    }
}

public struct LibreReverseAdmittedFrame: Equatable, Sendable {
    public let id: Int64
    public let segmentID: Int64?
    /// Exact Segment value handed to the canonical recording timeline update.
    /// Nil is the proven out-of-order admission result.
    public let segment: TimelineSegment?
    public let createdAt: Date
    public let imageFileName: String
    public let context: LibreReverseCaptureContext?
    public let encodingStatus: String

    public init(
        id: Int64,
        segmentID: Int64?,
        segment: TimelineSegment? = nil,
        createdAt: Date,
        imageFileName: String,
        context: LibreReverseCaptureContext?,
        encodingStatus: String
    ) {
        self.id = id
        self.segmentID = segmentID
        self.segment = segment
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.context = context
        self.encodingStatus = encodingStatus
    }
}

public struct LibreReversePendingOCRFrame: Equatable, Sendable {
    public let id: Int64
    public let imageFileName: String

    public init(id: Int64, imageFileName: String) {
        self.id = id
        self.imageFileName = imageFileName
    }
}

public struct LibreReverseRemovableSourceImage: Equatable, Sendable {
    public let frameID: Int64
    public let imageFileName: String

    public init(frameID: Int64, imageFileName: String) {
        self.frameID = frameID
        self.imageFileName = imageFileName
    }
}

public struct LibreReverseRecordedChunk: Equatable, Sendable {
    public let relativeMediaPath: String
    public let xid: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let frames: [LibreReverseRecordedFrame]

    public init(
        relativeMediaPath: String,
        xid: String,
        width: Int,
        height: Int,
        frameRate: Double = 30,
        frames: [LibreReverseRecordedFrame]
    ) {
        self.relativeMediaPath = relativeMediaPath
        self.xid = xid
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.frames = frames
    }
}

public struct LibreReverseTranscriptWordInput: Equatable, Sendable {
    public let speechSource: String
    public let word: String
    /// Raw persisted `transcript_word.timeOffset` units. Unit conversion
    /// belongs at the transcription adapter boundary.
    public let timeOffset: Int
    public let fullTextOffset: Int?
    /// Raw persisted `transcript_word.duration` units.
    public let duration: Int

    public init(
        speechSource: String,
        word: String,
        timeOffset: Int,
        fullTextOffset: Int?,
        duration: Int
    ) {
        self.speechSource = speechSource
        self.word = word
        self.timeOffset = timeOffset
        self.fullTextOffset = fullTextOffset
        self.duration = duration
    }
}

public struct LibreReverseMeetingEventInput: Equatable, Sendable {
    public let type: String
    public let status: String
    public let title: String?
    public let participants: String?
    public let detailsJSON: String?
    public let calendarID: String?
    public let calendarEventID: String?
    public let calendarSeriesID: String?

    public init(
        type: String = "meeting",
        status: String = "completed",
        title: String? = nil,
        participants: String? = nil,
        detailsJSON: String? = nil,
        calendarID: String? = nil,
        calendarEventID: String? = nil,
        calendarSeriesID: String? = nil
    ) {
        self.type = type
        self.status = status
        self.title = title
        self.participants = participants
        self.detailsJSON = detailsJSON
        self.calendarID = calendarID
        self.calendarEventID = calendarEventID
        self.calendarSeriesID = calendarSeriesID
    }
}

public struct LibreReverseMeetingPublication: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let windowName: String?
    public let browserURL: String?
    public let browserProfile: String?
    public let relativeMediaPath: String
    public let xid: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let audioStartTime: Date
    public let duration: TimeInterval
    public let transcriptText: String
    public let transcriptWords: [LibreReverseTranscriptWordInput]
    public let event: LibreReverseMeetingEventInput?

    public init(
        startDate: Date,
        endDate: Date,
        windowName: String? = nil,
        browserURL: String? = nil,
        browserProfile: String? = nil,
        relativeMediaPath: String,
        xid: String,
        width: Int,
        height: Int,
        frameRate: Double,
        audioStartTime: Date,
        duration: TimeInterval,
        transcriptText: String = "",
        transcriptWords: [LibreReverseTranscriptWordInput] = [],
        event: LibreReverseMeetingEventInput? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.windowName = windowName
        self.browserURL = browserURL
        self.browserProfile = browserProfile
        self.relativeMediaPath = relativeMediaPath
        self.xid = xid
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.audioStartTime = audioStartTime
        self.duration = duration
        self.transcriptText = transcriptText
        self.transcriptWords = transcriptWords
        self.event = event
    }
}

public struct LibreReversePublishedMeeting: Equatable, Sendable {
    public let segmentID: Int64
    public let videoID: Int64
    public let frameID: Int64
    public let audioID: Int64
    public let eventID: Int64?
    public let transcriptDocumentID: Int64?
    public let relativeMediaPath: String
    public let startedAt: Date

    public init(
        segmentID: Int64,
        videoID: Int64,
        frameID: Int64,
        audioID: Int64,
        eventID: Int64?,
        transcriptDocumentID: Int64?,
        relativeMediaPath: String,
        startedAt: Date
    ) {
        self.segmentID = segmentID
        self.videoID = videoID
        self.frameID = frameID
        self.audioID = audioID
        self.eventID = eventID
        self.transcriptDocumentID = transcriptDocumentID
        self.relativeMediaPath = relativeMediaPath
        self.startedAt = startedAt
    }
}

public enum LibreReverseLibraryStoreError: Error, Equatable {
    case invalidMediaPath(String)
    case missingMedia(String)
    case invalidFrameSequence
    case invalidMeeting(String)
    case invalidTranscript(String)
    case unableToOpenDatabase(String)
    case unableToApplyKey(Int32)
    case sqlite(String)
    case transactionOutcomeUnknown(String)
}

public enum LibreReverseFrameStarOwner: Equatable, Sendable {
    case primary
    case shard(id: Int64, state: LibreReverseShardState)
}

public struct LibreReverseFrameStarMutation: Equatable, Sendable {
    public let frameID: Int64
    public let wallDate: Date
    public let isStarred: Bool
    public let owner: LibreReverseFrameStarOwner

    public init(
        frameID: Int64,
        wallDate: Date,
        isStarred: Bool,
        owner: LibreReverseFrameStarOwner
    ) {
        self.frameID = frameID
        self.wallDate = wallDate
        self.isStarred = isStarred
        self.owner = owner
    }
}

/// Canonical screen-recording write boundary for frame and segment
/// admission, video finalization, and atomic deferred transactions.
public enum LibreReverseLibraryStore {
    /// Resolves a previously committed meeting by its durable publication XID.
    /// This closes the restart window after SQLite commit but before staging
    /// cleanup, allowing publication recovery to be idempotent.
    public static func publishedMeeting(
        xid: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReversePublishedMeeting? {
        try withDatabase(configuration, create: false) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                """
                SELECT s.id,v.id,
                  (SELECT MIN(id) FROM frame WHERE videoId=v.id),
                  (SELECT MIN(id) FROM audio WHERE segmentId=s.id),
                  (SELECT MIN(id) FROM event WHERE segmentID=s.id),
                  (SELECT MIN(docid) FROM doc_segment WHERE segmentId=s.id AND frameId IS NULL),
                  v.path,s.startDate
                FROM video v
                JOIN (SELECT DISTINCT segmentId,videoId FROM frame) anchor
                  ON anchor.videoId=v.id
                JOIN segment s ON s.id=anchor.segmentId
                WHERE v.xid=? AND s.type=1
                ORDER BY v.id
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            bind(xid, to: statement, index: 1)
            let firstStatus = sqlite3_step(statement)
            if firstStatus == SQLITE_DONE { return nil }
            guard firstStatus == SQLITE_ROW,
                sqlite3_column_type(statement, 2) != SQLITE_NULL,
                sqlite3_column_type(statement, 3) != SQLITE_NULL,
                let relativeMediaPath = optionalString(statement, column: 6),
                let startValue = optionalString(statement, column: 7),
                let startedAt = databaseDateFormatter.date(from: startValue)
            else {
                throw LibreReverseLibraryStoreError.invalidMeeting(
                    "Meeting publication \(xid) has an incomplete canonical graph"
                )
            }
            let result = LibreReversePublishedMeeting(
                segmentID: sqlite3_column_int64(statement, 0),
                videoID: sqlite3_column_int64(statement, 1),
                frameID: sqlite3_column_int64(statement, 2),
                audioID: sqlite3_column_int64(statement, 3),
                eventID: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 4),
                transcriptDocumentID: sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 5),
                relativeMediaPath: relativeMediaPath,
                startedAt: startedAt
            )
            let secondStatus = sqlite3_step(statement)
            if secondStatus == SQLITE_ROW {
                throw LibreReverseLibraryStoreError.invalidMeeting(
                    "Meeting publication XID is ambiguous: \(xid)"
                )
            }
            guard secondStatus == SQLITE_DONE else { throw sqliteError(database) }
            return result
        }
    }

    public static func meetingPublicationMatches(
        xid: String,
        segmentID: Int64,
        videoID: Int64,
        relativeMediaPath: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Bool {
        try withDatabase(configuration, create: false) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                """
                SELECT 1 FROM video v
                JOIN frame f ON f.videoId=v.id
                JOIN segment s ON s.id=f.segmentId
                WHERE v.xid=? AND v.id=? AND v.path=? AND s.id=? AND s.type=1
                LIMIT 1
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            bind(xid, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, videoID)
            bind(relativeMediaPath, to: statement, index: 3)
            sqlite3_bind_int64(statement, 4, segmentID)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public static func meetingTitle(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> String {
        try withDatabase(configuration, create: false) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                "SELECT COALESCE(windowName,'') FROM segment WHERE id=? AND type=1",
                &raw
            )
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, segmentID)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw LibreReverseLibraryStoreError.invalidMeeting(
                    "meeting segment \(segmentID) is not present in the primary library"
                )
            }
            return optionalString(statement, column: 0) ?? ""
        }
    }

    public static func initialize(_ configuration: LibreReverseLibraryConfiguration) throws {
        try LibreReverseLibraryKey.createIfNeeded(at: configuration.keyFileURL)
        try FileManager.default.createDirectory(
            at: configuration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configuration.mediaRoot,
            withIntermediateDirectories: true
        )
        try withDatabase(configuration, create: true) { database in
            try execute(database, LibrarySchema.schemaSQL)
            try execute(
                database,
                """
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS capture_journal(
                  frameId INTEGER PRIMARY KEY NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                  sessionId TEXT NOT NULL,admittedAt TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS librereverse_summary_retry(
                  eventID INTEGER PRIMARY KEY REFERENCES event(id) ON DELETE CASCADE,
                  attempts INTEGER NOT NULL CHECK(attempts > 0),retryAfter REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS document_id_sequence(
                  id INTEGER PRIMARY KEY CHECK(id=1),lastID INTEGER NOT NULL CHECK(lastID<=0)
                );
                CREATE TABLE IF NOT EXISTS frame_processing(
                  id INTEGER NOT NULL,
                  processingType TEXT NOT NULL,
                  createdAt TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
                  UNIQUE(id,processingType)
                );
                """)
        }
        try LibreReverseArchiveStore.initialize(configuration)
        try LibreReverseShardStore.initialize(configuration)
        try withDatabase(configuration, create: false) { database in
            try ensureFrameIDHighWatermark(database)
        }
    }

    /// A previous version could replace an empty primary without its sequence.
    /// The always-local catalog still records exact maxima, even for remote shards.
    static func ensureFrameIDHighWatermark(_ database: OpaquePointer) throws {
        try execute(database, """
            INSERT INTO sqlite_sequence(name,seq)
            SELECT 'frame',COALESCE((SELECT MAX(maxFrameId) FROM library_shard),0)
             WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='frame');
            UPDATE sqlite_sequence SET seq=MAX(seq,
              COALESCE((SELECT MAX(maxFrameId) FROM library_shard),0),
              COALESCE((SELECT MAX(id) FROM frame),0)) WHERE name='frame';
            """)
    }

    /// Legacy FTS row IDs were implicitly allocated positive integers, and
    /// remote-only shards do not publish their maximum document ID. Reserve
    /// negative IDs for new documents so allocation remains safe while offline.
    /// The caller's write transaction owns this durable decreasing watermark.
    private static func allocateDocumentID(_ database: OpaquePointer) throws -> Int64 {
        try execute(database, """
            CREATE TABLE IF NOT EXISTS document_id_sequence(
              id INTEGER PRIMARY KEY CHECK(id=1),lastID INTEGER NOT NULL CHECK(lastID<=0)
            );
            INSERT OR IGNORE INTO document_id_sequence(id,lastID)
            SELECT 1,MIN(0,COALESCE(MIN(docid),0)) FROM doc_segment;
            UPDATE document_id_sequence SET lastID=MIN(lastID,
              COALESCE((SELECT MIN(docid) FROM doc_segment),0)) WHERE id=1;
            """)
        var raw: OpaquePointer?
        try prepare(database, "UPDATE document_id_sequence SET lastID=lastID-1 WHERE id=1 AND lastID>\(Int64.min) RETURNING lastID", &raw)
        let statement = try unwrap(raw, database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LibreReverseLibraryStoreError.sqlite("Document identifier space is exhausted")
        }
        let identifier = sqlite3_column_int64(statement, 0)
        try stepDone(statement, database)
        return identifier
    }

    /// Capture admission chooses or creates the current screen segment, then
    /// inserts its durable deferred frame before passing it to the video writer.
    @discardableResult
    public static func admitFrame(
        createdAt: Date,
        imageFileName: String,
        context: LibreReverseCaptureContext?,
        isStarred: Bool = false,
        captureSessionID: String? = nil,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseAdmittedFrame {
        try withDatabase(configuration, create: false, session: session) { database in
            // Reserve the writer before reading the current segment. In WAL
            // mode a DEFERRED read snapshot cannot upgrade after another writer
            // (for example meeting publication) commits; busy_timeout cannot
            // repair that stale snapshot. IMMEDIATE waits before taking it.
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                let current = try currentCapturedScreenSegment(database)
                let segment: TimelineSegment?
                if let current, createdAt < current.startDate {
                    // Exact out-of-order branch: the Frame is still inserted,
                    // but its optional Segment relation is nil.
                    segment = nil
                } else if let current,
                    createdAt.timeIntervalSince(current.endDate) < 240,
                    current.context == context
                {
                    // Reused segments end at the raw frame time. Only new segments add
                    // the capture interval to their initial end date.
                    let candidateEnd = createdAt
                    if candidateEnd > current.endDate {
                        try updateSegmentEnd(
                            id: current.id,
                            endDate: candidateEnd,
                            database: database
                        )
                    }
                    segment = timelineSegment(
                        id: current.id,
                        startDate: current.startDate,
                        endDate: max(current.endDate, candidateEnd),
                        context: current.context
                    )
                } else {
                    let segmentID = try insertCapturedScreenSegment(
                        createdAt: createdAt,
                        context: context,
                        database: database
                    )
                    segment = timelineSegment(
                        id: segmentID,
                        startDate: createdAt,
                        endDate: createdAt.addingTimeInterval(
                            CaptureContract.productionCaptureIntervalSeconds
                        ),
                        context: context
                    )
                }
                let segmentID = segment?.rawID

                var raw: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT INTO frame(createdAt,imageFileName,segmentId,isStarred,encodingStatus)
                    VALUES(?,?,?,?,?)
                    """, &raw)
                let statement = try unwrap(raw, database)
                bind(databaseDate(createdAt), to: statement, index: 1)
                bind(imageFileName, to: statement, index: 2)
                if let segmentID {
                    sqlite3_bind_int64(statement, 3, segmentID)
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                sqlite3_bind_int(statement, 4, isStarred ? 1 : 0)
                bind(CloneFrameEncodingStatus.deferred.rawValue, to: statement, index: 5)
                try stepDone(statement, database)
                let frameID = sqlite3_last_insert_rowid(database)
                sqlite3_finalize(statement)
                raw = nil
                try prepare(
                    database,
                    """
                        INSERT OR IGNORE INTO frame_processing(id,processingType,createdAt)
                        VALUES(?,'ocr',?)
                    """, &raw)
                let processing = try unwrap(raw, database)
                sqlite3_bind_int64(processing, 1, frameID)
                bind(databaseDate(createdAt), to: processing, index: 2)
                try stepDone(processing, database)
                sqlite3_finalize(processing)
                raw = nil
                try prepare(
                    database,
                    """
                        INSERT INTO capture_journal(frameId,sessionId,admittedAt)
                        VALUES(?,?,?)
                    """, &raw)
                let journal = try unwrap(raw, database)
                sqlite3_bind_int64(journal, 1, frameID)
                bind(captureSessionID ?? "unscoped", to: journal, index: 2)
                bind(databaseDate(createdAt), to: journal, index: 3)
                try stepDone(journal, database)
                sqlite3_finalize(journal)
                try execute(database, "COMMIT")
                return LibreReverseAdmittedFrame(
                    id: frameID,
                    segmentID: segmentID,
                    segment: segment,
                    createdAt: createdAt,
                    imageFileName: imageFileName,
                    context: context,
                    encodingStatus: CloneFrameEncodingStatus.deferred.rawValue
                )
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func loadDeferredFrames(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [LibreReverseAdmittedFrame] {
        try loadRecoverableFrames(configuration: configuration, deferredOnly: true)
    }

    /// Startup-only crash recovery includes every state which does not yet own
    /// a committed canonical video. Keep `loadDeferredFrames` strict because it
    /// selects only frames eligible for deferred encoding.
    public static func loadRecoverableFrames(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseAdmittedFrame] {
        try loadRecoverableFrames(configuration: configuration, deferredOnly: false, session: session)
    }

    private static func loadRecoverableFrames(
        configuration: LibreReverseLibraryConfiguration,
        deferredOnly: Bool,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseAdmittedFrame] {
        try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            // A process exit can leave a frame in any pre-success state:
            // `deferred` before AVAssetWriter accepts it, `pending` after the
            // writer accepts it but before chunk commit, or `failed` after an
            // interrupted encode. All three still own a durable source PNG and
            // are restartable. The builder applies no ordering; do not invent
            // FIFO/LIFO.
            let predicate =
                deferredOnly
                ? "f.encodingStatus=?"
                : "f.encodingStatus!=? AND EXISTS(SELECT 1 FROM capture_journal j WHERE j.frameId=f.id)"
            try prepare(
                database,
                """
                SELECT f.id,f.segmentId,f.createdAt,f.imageFileName,
                       s.bundleID,s.windowName,s.browserUrl,s.browserProfile,
                       s.startDate,s.endDate,s.type,f.encodingStatus
                  FROM frame f
                  LEFT JOIN segment s ON s.id=f.segmentId
                 WHERE \(predicate)
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            bind(
                deferredOnly
                    ? CloneFrameEncodingStatus.deferred.rawValue
                    : CloneFrameEncodingStatus.success.rawValue,
                to: statement,
                index: 1
            )
            var result: [LibreReverseAdmittedFrame] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                guard
                    let createdAt = databaseDateFormatter.date(
                        from: String(cString: sqlite3_column_text(statement, 2))
                    )
                else {
                    throw LibreReverseLibraryStoreError.sqlite("invalid deferred-frame date")
                }
                let context: LibreReverseCaptureContext? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                        && sqlite3_column_type(statement, 5) == SQLITE_NULL
                        && sqlite3_column_type(statement, 6) == SQLITE_NULL
                        && sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil
                    : LibreReverseCaptureContext(
                        bundleID: optionalString(statement, column: 4),
                        windowName: optionalString(statement, column: 5),
                        browserURL: optionalString(statement, column: 6),
                        browserProfile: optionalString(statement, column: 7)
                    )
                let segmentID =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 1)
                let segment: TimelineSegment?
                if let segmentID,
                    let startValue = optionalString(statement, column: 8),
                    let endValue = optionalString(statement, column: 9),
                    let startDate = databaseDateFormatter.date(from: startValue),
                    let endDate = databaseDateFormatter.date(from: endValue),
                    let type = SegmentType(
                        rawValue: Int(sqlite3_column_int64(statement, 10))
                    )
                {
                    segment = TimelineSegment(
                        startDate: startDate,
                        endDate: endDate,
                        bundleID: context?.bundleID,
                        windowName: context?.windowName,
                        browserURL: context?.browserURL,
                        browserProfile: context?.browserProfile,
                        rawID: segmentID,
                        rawType: type
                    )
                } else {
                    segment = nil
                }
                result.append(
                    LibreReverseAdmittedFrame(
                        id: sqlite3_column_int64(statement, 0),
                        segmentID: segmentID,
                        segment: segment,
                        createdAt: createdAt,
                        imageFileName: String(cString: sqlite3_column_text(statement, 3)),
                        context: context,
                        encodingStatus: String(cString: sqlite3_column_text(statement, 11))
                    ))
            }
        }
    }

    public static func updateFrameEncodingStatus(
        frameID: Int64,
        status: CloneFrameEncodingStatus,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            try prepare(database, "UPDATE frame SET encodingStatus=? WHERE id=?", &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            bind(status.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, frameID)
            try stepDone(statement, database)
            guard sqlite3_changes(database) == 1 else {
                throw LibreReverseLibraryStoreError.sqlite("frame not found: \(frameID)")
            }
        }
    }

    /// Changes the user's star without rewriting immutable or remote media.
    ///
    /// Active frames store stars in `frame.isStarred`. For sealed 30-day shards,
    /// the primary `shard_star` catalog is authoritative: presence means starred
    /// and absence means unstarred. This supports remote-only history while
    /// archive transfers retain ownership of the immutable payload object.
    @discardableResult
    public static func setFrameStarred(
        frameID: Int64,
        wallDate: Date,
        isStarred: Bool,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseFrameStarMutation {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            var committed = false
            defer {
                if !committed { try? execute(database, "ROLLBACK") }
            }

            var raw: OpaquePointer?
            try prepare(
                database,
                "UPDATE frame SET isStarred=? WHERE id=? AND createdAt=?",
                &raw
            )
            let primary = try unwrap(raw, database)
            sqlite3_bind_int(primary, 1, isStarred ? 1 : 0)
            sqlite3_bind_int64(primary, 2, frameID)
            bind(databaseDate(wallDate), to: primary, index: 3)
            try stepDone(primary, database)
            let updatedPrimary = sqlite3_changes(database) == 1
            sqlite3_finalize(primary)

            let owner: LibreReverseFrameStarOwner
            if updatedPrimary {
                owner = .primary
            } else {
                var metadata: OpaquePointer?
                try prepare(
                    database,
                    "SELECT epochStart,routingState FROM shard_metadata WHERE id=1",
                    &metadata
                )
                let metadataStatement = try unwrap(metadata, database)
                guard sqlite3_step(metadataStatement) == SQLITE_ROW,
                    let epochText = optionalString(metadataStatement, column: 0),
                    let epoch = databaseDateFormatter.date(from: epochText)
                        ?? parseShardEpoch(epochText),
                    optionalString(metadataStatement, column: 1) == "sharded"
                else {
                    sqlite3_finalize(metadataStatement)
                    throw LibreReverseLibraryStoreError.sqlite(
                        "frame not found in primary or shard catalog: \(frameID)"
                    )
                }
                sqlite3_finalize(metadataStatement)

                let ordinal = LibreReverseShardInterval.ordinal(
                    containing: wallDate,
                    epochStart: epoch
                )
                var shardRaw: OpaquePointer?
                try prepare(
                    database,
                    """
                    SELECT id,state,minFrameId,maxFrameId
                      FROM library_shard
                     WHERE ordinal=?
                     ORDER BY generation DESC
                     LIMIT 1
                    """,
                    &shardRaw
                )
                let shard = try unwrap(shardRaw, database)
                sqlite3_bind_int64(shard, 1, ordinal)
                guard sqlite3_step(shard) == SQLITE_ROW,
                    let stateText = optionalString(shard, column: 1),
                    let state = LibreReverseShardState(rawValue: stateText)
                else {
                    sqlite3_finalize(shard)
                    throw LibreReverseLibraryStoreError.sqlite(
                        "shard owner not found for frame \(frameID)"
                    )
                }
                let shardID = sqlite3_column_int64(shard, 0)
                let minimum = sqlite3_column_type(shard, 2) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(shard, 2)
                let maximum = sqlite3_column_type(shard, 3) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(shard, 3)
                sqlite3_finalize(shard)
                if let minimum, frameID < minimum {
                    throw LibreReverseLibraryStoreError.sqlite(
                        "frame \(frameID) is outside shard \(shardID)"
                    )
                }
                if let maximum, frameID > maximum {
                    throw LibreReverseLibraryStoreError.sqlite(
                        "frame \(frameID) is outside shard \(shardID)"
                    )
                }

                var starRaw: OpaquePointer?
                if isStarred {
                    try prepare(
                        database,
                        """
                        INSERT INTO shard_star(frameId,createdAt,shardId)
                        VALUES(?,?,?)
                        ON CONFLICT(frameId) DO UPDATE SET
                          createdAt=excluded.createdAt,shardId=excluded.shardId
                        """,
                        &starRaw
                    )
                    let star = try unwrap(starRaw, database)
                    sqlite3_bind_int64(star, 1, frameID)
                    bind(databaseDate(wallDate), to: star, index: 2)
                    sqlite3_bind_int64(star, 3, shardID)
                    try stepDone(star, database)
                    sqlite3_finalize(star)
                } else {
                    try prepare(
                        database,
                        "DELETE FROM shard_star WHERE frameId=? AND shardId=?",
                        &starRaw
                    )
                    let star = try unwrap(starRaw, database)
                    sqlite3_bind_int64(star, 1, frameID)
                    sqlite3_bind_int64(star, 2, shardID)
                    try stepDone(star, database)
                    sqlite3_finalize(star)
                }
                owner = .shard(id: shardID, state: state)
            }

            try execute(database, "COMMIT")
            committed = true
            return LibreReverseFrameStarMutation(
                frameID: frameID,
                wallDate: wallDate,
                isStarred: isStarred,
                owner: owner
            )
        }
    }

    /// Durable OCR work uses `frame_processing`. Returning IDs in admission
    /// order makes recovery deterministic without scanning OCR nodes or FTS.
    public static func pendingOCRFrameIDs(
        limit: Int = 128,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [Int64] {
        try pendingOCRFrames(limit: limit, configuration: configuration).map(\.id)
    }

    public static func pendingOCRFrames(
        limit: Int = 128,
        afterFrameID: Int64? = nil,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReversePendingOCRFrame] {
        guard limit > 0 else { return [] }
        return try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                """
                    SELECT fp.id,f.imageFileName
                      FROM frame_processing fp
                      JOIN frame f ON f.id=fp.id
                     WHERE fp.processingType='ocr' AND (? IS NULL OR fp.id>?)
                     ORDER BY fp.id
                     LIMIT ?
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            if let afterFrameID {
                sqlite3_bind_int64(statement, 1, afterFrameID)
                sqlite3_bind_int64(statement, 2, afterFrameID)
            } else {
                sqlite3_bind_null(statement, 1)
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int64(statement, 3, Int64(limit))
            var result: [LibreReversePendingOCRFrame] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    result.append(
                        LibreReversePendingOCRFrame(
                            id: sqlite3_column_int64(statement, 0),
                            imageFileName: String(cString: sqlite3_column_text(statement, 1))
                        ))
                case SQLITE_DONE:
                    return result
                default:
                    throw sqliteError(database)
                }
            }
        }
    }

    /// Bounds one recovery pass so live admission cannot extend it indefinitely.
    public static func pendingOCRFrameHighWatermark(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Int64? {
        try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            try prepare(database, "SELECT MAX(id) FROM frame_processing WHERE processingType='ocr'", &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
            return sqlite3_column_type(statement, 0) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 0)
        }
    }

    /// A temporary source image is dispensable only after both halves of the
    /// admission pipeline are durable: its MP4 frame and its OCR document.
    public static func canRemoveSourceImage(
        frameID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Bool {
        try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                """
                    SELECT s.type=0
                           AND f.encodingStatus='success'
                           AND NOT EXISTS(
                             SELECT 1 FROM frame_processing fp
                              WHERE fp.id=f.id AND fp.processingType='ocr'
                           )
                      FROM frame f
                      JOIN segment s ON s.id=f.segmentId
                     WHERE f.id=?
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, frameID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    /// Finds crash/interruption leftovers whose two durable successors already
    /// exist. The bounded primary owns at most the active shard interval, so a
    /// launch reconciliation is cheap and never guesses about remote shards.
    public static func removableSourceImages(
        limit: Int = 100_000,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseRemovableSourceImage] {
        guard limit > 0 else { return [] }
        return try withDatabase(configuration, create: false, session: session) { database in
            var raw: OpaquePointer?
            try prepare(
                database,
                """
                    SELECT f.id,f.imageFileName
                      FROM frame f
                      JOIN segment s ON s.id=f.segmentId
                     WHERE s.type=0
                       AND f.encodingStatus='success'
                       AND NOT EXISTS(
                         SELECT 1 FROM frame_processing fp
                          WHERE fp.id=f.id AND fp.processingType='ocr'
                       )
                     ORDER BY f.id
                     LIMIT ?
                """, &raw)
            let statement = try unwrap(raw, database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var result: [LibreReverseRemovableSourceImage] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    result.append(
                        LibreReverseRemovableSourceImage(
                            frameID: sqlite3_column_int64(statement, 0),
                            imageFileName: String(cString: sqlite3_column_text(statement, 1))
                        ))
                case SQLITE_DONE:
                    return result
                default:
                    throw sqliteError(database)
                }
            }
        }
    }

    /// Atomically replaces one frame's search document and geometry and then
    /// clears its durable OCR work item. Readers can observe either the old
    /// complete document or the new complete document, never a partial node
    /// batch.
    public static func commitOCRDocument(
        frameID: Int64,
        document: OCRDocument,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: session) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var raw: OpaquePointer?
                try prepare(
                    database,
                    """
                        SELECT f.segmentId,coalesce(s.windowName,'')
                          FROM frame f
                          LEFT JOIN segment s ON s.id=f.segmentId
                         WHERE f.id=?
                    """, &raw)
                let frame = try unwrap(raw, database)
                sqlite3_bind_int64(frame, 1, frameID)
                guard sqlite3_step(frame) == SQLITE_ROW,
                    sqlite3_column_type(frame, 0) != SQLITE_NULL
                else {
                    sqlite3_finalize(frame)
                    throw LibreReverseLibraryStoreError.sqlite(
                        "OCR frame missing canonical segment: \(frameID)"
                    )
                }
                let segmentID = sqlite3_column_int64(frame, 0)
                let title = optionalString(frame, column: 1) ?? ""
                sqlite3_finalize(frame)

                try prepare(database, "SELECT docid FROM doc_segment WHERE frameId=?", &raw)
                let existing = try unwrap(raw, database)
                sqlite3_bind_int64(existing, 1, frameID)
                var existingDocID: Int64?
                if sqlite3_step(existing) == SQLITE_ROW {
                    existingDocID = sqlite3_column_int64(existing, 0)
                }
                sqlite3_finalize(existing)

                try prepare(database, "DELETE FROM node WHERE frameId=?", &raw)
                let deleteNodes = try unwrap(raw, database)
                sqlite3_bind_int64(deleteNodes, 1, frameID)
                try stepDone(deleteNodes, database)
                sqlite3_finalize(deleteNodes)

                if let existingDocID {
                    try prepare(database, "DELETE FROM doc_segment WHERE docid=?", &raw)
                    let deleteMapping = try unwrap(raw, database)
                    sqlite3_bind_int64(deleteMapping, 1, existingDocID)
                    try stepDone(deleteMapping, database)
                    sqlite3_finalize(deleteMapping)

                    try prepare(database, "DELETE FROM searchRanking WHERE rowid=?", &raw)
                    let deleteDocument = try unwrap(raw, database)
                    sqlite3_bind_int64(deleteDocument, 1, existingDocID)
                    try stepDone(deleteDocument, database)
                    sqlite3_finalize(deleteDocument)

                    for table in ["search", "searchOffsets"] {
                        try prepare(database, "DELETE FROM \(table) WHERE rowid=?", &raw)
                        let deleteLegacyDocument = try unwrap(raw, database)
                        sqlite3_bind_int64(deleteLegacyDocument, 1, existingDocID)
                        try stepDone(deleteLegacyDocument, database)
                        sqlite3_finalize(deleteLegacyDocument)
                    }
                }

                let docID = try existingDocID ?? allocateDocumentID(database)
                try prepare(
                    database,
                    """
                        INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(?,?,?,?)
                    """, &raw)
                let search = try unwrap(raw, database)
                sqlite3_bind_int64(search, 1, docID)
                bind(document.text, to: search, index: 2)
                bind(document.otherText, to: search, index: 3)
                bind(title, to: search, index: 4)
                try stepDone(search, database)
                sqlite3_finalize(search)

                for table in ["search", "searchOffsets"] {
                    try prepare(
                        database,
                        """
                            INSERT INTO \(table)(rowid,text,otherText) VALUES(?,?,?)
                        """, &raw)
                    let legacySearch = try unwrap(raw, database)
                    sqlite3_bind_int64(legacySearch, 1, docID)
                    bind(document.text, to: legacySearch, index: 2)
                    bind(document.otherText, to: legacySearch, index: 3)
                    try stepDone(legacySearch, database)
                    sqlite3_finalize(legacySearch)
                }

                try prepare(
                    database,
                    """
                        INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(?,?,?)
                    """, &raw)
                let mapping = try unwrap(raw, database)
                sqlite3_bind_int64(mapping, 1, docID)
                sqlite3_bind_int64(mapping, 2, segmentID)
                sqlite3_bind_int64(mapping, 3, frameID)
                try stepDone(mapping, database)
                sqlite3_finalize(mapping)

                try prepare(
                    database,
                    """
                        INSERT INTO node(
                          frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,windowIndex
                        ) VALUES(?,?,?,?,?,?,?,?,?)
                    """, &raw)
                let node = try unwrap(raw, database)
                defer { sqlite3_finalize(node) }
                for value in document.nodes {
                    sqlite3_reset(node)
                    sqlite3_clear_bindings(node)
                    sqlite3_bind_int64(node, 1, frameID)
                    sqlite3_bind_int64(node, 2, Int64(value.nodeOrder))
                    sqlite3_bind_int64(node, 3, Int64(value.textOffset))
                    sqlite3_bind_int64(node, 4, Int64(value.textLength))
                    sqlite3_bind_double(node, 5, value.leftX)
                    sqlite3_bind_double(node, 6, value.topY)
                    sqlite3_bind_double(node, 7, value.width)
                    sqlite3_bind_double(node, 8, value.height)
                    sqlite3_bind_int64(node, 9, Int64(value.windowIndex))
                    try stepDone(node, database)
                }

                try prepare(
                    database,
                    """
                        DELETE FROM frame_processing WHERE id=? AND processingType='ocr'
                    """, &raw)
                let completed = try unwrap(raw, database)
                sqlite3_bind_int64(completed, 1, frameID)
                try stepDone(completed, database)
                sqlite3_finalize(completed)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public static func commitRecordedChunk(
        _ chunk: LibreReverseRecordedChunk,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Int64 {
        guard isSafeRelativePath(chunk.relativeMediaPath),
            VideoStorage.isCanonicalRelativePath(
                chunk.relativeMediaPath,
                xid: chunk.xid
            )
        else {
            throw LibreReverseLibraryStoreError.invalidMediaPath(chunk.relativeMediaPath)
        }
        let expectedIndices = Array(0..<chunk.frames.count)
        guard chunk.width > 0, chunk.height > 0, chunk.frameRate > 0,
            chunk.frames.map(\.videoFrameIndex) == expectedIndices
        else {
            throw LibreReverseLibraryStoreError.invalidFrameSequence
        }
        let mediaURL = configuration.mediaRoot.appendingPathComponent(chunk.relativeMediaPath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw LibreReverseLibraryStoreError.missingMedia(chunk.relativeMediaPath)
        }
        let fileSize = try mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize

        return try withDatabase(configuration, create: false, session: session) { database in
            try execute(database, "BEGIN DEFERRED TRANSACTION")
            do {
                var rawVideo: OpaquePointer?
                let videoSQL = """
                    INSERT INTO video(frameRate,height,path,width,fileSize,xid)
                    VALUES(?,?,?,?,?,?)
                    """
                try prepare(database, videoSQL, &rawVideo)
                let video = try unwrap(rawVideo, database)
                defer { sqlite3_finalize(video) }
                sqlite3_bind_double(video, 1, chunk.frameRate)
                sqlite3_bind_int64(video, 2, Int64(chunk.height))
                bind(chunk.relativeMediaPath, to: video, index: 3)
                sqlite3_bind_int64(video, 4, Int64(chunk.width))
                if let fileSize {
                    sqlite3_bind_int64(video, 5, Int64(fileSize))
                } else {
                    sqlite3_bind_null(video, 5)
                }
                bind(chunk.xid, to: video, index: 6)
                try stepDone(video, database)
                let videoID = sqlite3_last_insert_rowid(database)

                var rawFrameStatement: OpaquePointer?
                let frameSQL = """
                    UPDATE frame
                       SET videoId=?,videoFrameIndex=?,encodingStatus=?
                     WHERE id=?
                    """
                try prepare(database, frameSQL, &rawFrameStatement)
                let frameStatement = try unwrap(rawFrameStatement, database)
                defer { sqlite3_finalize(frameStatement) }
                for frame in chunk.frames {
                    sqlite3_reset(frameStatement)
                    sqlite3_clear_bindings(frameStatement)
                    sqlite3_bind_int64(frameStatement, 1, videoID)
                    sqlite3_bind_int64(frameStatement, 2, Int64(frame.videoFrameIndex))
                    bind(CloneFrameEncodingStatus.success.rawValue, to: frameStatement, index: 3)
                    sqlite3_bind_int64(frameStatement, 4, frame.frameID)
                    try stepDone(frameStatement, database)
                    guard sqlite3_changes(database) == 1 else {
                        throw LibreReverseLibraryStoreError.sqlite(
                            "frame not found during finalization: \(frame.frameID)"
                        )
                    }
                }
                if !chunk.frames.isEmpty {
                    let frameIDs = chunk.frames.map { String($0.frameID) }.joined(separator: ",")
                    try execute(
                        database,
                        "DELETE FROM capture_journal WHERE frameId IN (\(frameIDs))"
                    )
                }
                try execute(
                    database,
                    """
                    INSERT INTO video_frame_bounds(videoId,minCreatedAt,maxCreatedAt,frameCount)
                    SELECT \(videoID),MIN(createdAt),MAX(createdAt),COUNT(*)
                      FROM frame WHERE videoId=\(videoID)
                    ON CONFLICT(videoId) DO UPDATE SET
                      minCreatedAt=excluded.minCreatedAt,
                      maxCreatedAt=excluded.maxCreatedAt,
                      frameCount=excluded.frameCount
                    """)
                try LibreReverseArchiveStore.enqueueFinalizedVideo(
                    videoID: videoID,
                    relativePath: chunk.relativeMediaPath,
                    xid: chunk.xid,
                    byteCount: Int64(fileSize ?? 0),
                    database: database
                )
                try execute(database, "COMMIT")
                return videoID
            } catch {
                do {
                    try execute(database, "ROLLBACK")
                } catch let rollbackError {
                    throw LibreReverseLibraryStoreError.transactionOutcomeUnknown(
                        "recorded chunk commit failed (\(error)); rollback failed (\(rollbackError))"
                    )
                }
                throw error
            }
        }
    }

    /// Atomically publishes a completed meeting into the segment, video, frame,
    /// audio, event, and transcript graph. Audio and video share one A/V MP4,
    /// so archive and residency operations cannot separate the two tracks.
    public static func publishMeeting(
        _ meeting: LibreReverseMeetingPublication,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReversePublishedMeeting {
        try validateMeeting(meeting)
        let mediaURL = configuration.mediaRoot.appendingPathComponent(meeting.relativeMediaPath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw LibreReverseLibraryStoreError.missingMedia(meeting.relativeMediaPath)
        }
        let fileSize = try mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        return try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var raw: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT INTO segment(
                      bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type
                    ) VALUES(?,?,?,?,?,?,1)
                    """, &raw)
                var statement = try unwrap(raw, database)
                bind(SearchFacets.meetingRecorderBundleID, to: statement, index: 1)
                bind(databaseDate(meeting.startDate), to: statement, index: 2)
                bind(databaseDate(meeting.endDate), to: statement, index: 3)
                bindOptional(meeting.windowName, to: statement, index: 4)
                bindOptional(meeting.browserURL, to: statement, index: 5)
                bindOptional(meeting.browserProfile, to: statement, index: 6)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                let segmentID = sqlite3_last_insert_rowid(database)

                raw = nil
                try prepare(
                    database,
                    """
                    INSERT INTO video(
                      frameRate,height,path,width,captureType,fileSize,xid,local
                    ) VALUES(?,?,?,?,?,?,?,1)
                    """, &raw)
                statement = try unwrap(raw, database)
                sqlite3_bind_double(statement, 1, meeting.frameRate)
                sqlite3_bind_int64(statement, 2, Int64(meeting.height))
                bind(meeting.relativeMediaPath, to: statement, index: 3)
                sqlite3_bind_int64(statement, 4, Int64(meeting.width))
                bind("meeting", to: statement, index: 5)
                sqlite3_bind_int64(statement, 6, Int64(fileSize))
                bind(meeting.xid, to: statement, index: 7)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                let videoID = sqlite3_last_insert_rowid(database)

                // One durable anchor maps the meeting Video into the same
                // frame-bounded archive and shard ownership machinery used by
                // ordinary recordings. Audio segments are excluded from the
                // screenshot UI, so this does not synthesize a visual-memory card.
                raw = nil
                try prepare(
                    database,
                    """
                    INSERT INTO frame(
                      createdAt,imageFileName,segmentId,videoId,videoFrameIndex,
                      isStarred,encodingStatus
                    ) VALUES(?,?,?, ?,0,0,'success')
                    """, &raw)
                statement = try unwrap(raw, database)
                bind(databaseDate(meeting.startDate), to: statement, index: 1)
                bind("", to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, segmentID)
                sqlite3_bind_int64(statement, 4, videoID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                let frameID = sqlite3_last_insert_rowid(database)

                raw = nil
                try prepare(
                    database,
                    """
                    INSERT INTO video_frame_bounds(videoId,minCreatedAt,maxCreatedAt,frameCount)
                    VALUES(?,?,?,1)
                    """, &raw)
                statement = try unwrap(raw, database)
                sqlite3_bind_int64(statement, 1, videoID)
                bind(databaseDate(meeting.startDate), to: statement, index: 2)
                bind(databaseDate(meeting.endDate), to: statement, index: 3)
                try stepDone(statement, database)
                sqlite3_finalize(statement)

                raw = nil
                try prepare(
                    database,
                    """
                    INSERT INTO audio(segmentId,path,startTime,duration) VALUES(?,?,?,?)
                    """, &raw)
                statement = try unwrap(raw, database)
                sqlite3_bind_int64(statement, 1, segmentID)
                bind(meeting.relativeMediaPath, to: statement, index: 2)
                bind(databaseDate(meeting.audioStartTime), to: statement, index: 3)
                sqlite3_bind_double(statement, 4, meeting.duration)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                let audioID = sqlite3_last_insert_rowid(database)

                let eventID = try meeting.event.map { event in
                    raw = nil
                    try prepare(
                        database,
                        """
                        INSERT INTO event(
                          type,status,title,participants,detailsJSON,calendarID,
                          calendarEventID,calendarSeriesID,segmentID
                        ) VALUES(?,?,?,?,?,?,?,?,?)
                        """, &raw)
                    let eventStatement = try unwrap(raw, database)
                    bind(event.type, to: eventStatement, index: 1)
                    bind(event.status, to: eventStatement, index: 2)
                    bindOptional(event.title, to: eventStatement, index: 3)
                    bindOptional(event.participants, to: eventStatement, index: 4)
                    bindOptional(event.detailsJSON, to: eventStatement, index: 5)
                    bindOptional(event.calendarID, to: eventStatement, index: 6)
                    bindOptional(event.calendarEventID, to: eventStatement, index: 7)
                    bindOptional(event.calendarSeriesID, to: eventStatement, index: 8)
                    sqlite3_bind_int64(eventStatement, 9, segmentID)
                    try stepDone(eventStatement, database)
                    sqlite3_finalize(eventStatement)
                    return sqlite3_last_insert_rowid(database)
                }

                let documentID = try replaceMeetingTranscript(
                    segmentID: segmentID,
                    title: meeting.event?.title ?? meeting.windowName ?? "",
                    transcriptText: meeting.transcriptText,
                    words: meeting.transcriptWords,
                    database: database
                )
                try LibreReverseArchiveStore.enqueueFinalizedVideo(
                    videoID: videoID,
                    relativePath: meeting.relativeMediaPath,
                    xid: meeting.xid,
                    byteCount: Int64(fileSize),
                    database: database
                )
                try execute(database, "COMMIT")
                return LibreReversePublishedMeeting(
                    segmentID: segmentID,
                    videoID: videoID,
                    frameID: frameID,
                    audioID: audioID,
                    eventID: eventID,
                    transcriptDocumentID: documentID,
                    relativeMediaPath: meeting.relativeMediaPath,
                    startedAt: meeting.startDate
                )
            } catch {
                do {
                    try execute(database, "ROLLBACK")
                } catch let rollbackError {
                    throw LibreReverseLibraryStoreError.transactionOutcomeUnknown(
                        "meeting publication failed (\(error)); rollback failed (\(rollbackError))"
                    )
                }
                throw error
            }
        }
    }

    /// Replaces partial or final words and all three search indexes in one
    /// transaction. Retrying cannot duplicate words or leave search documents
    /// out of sync with `transcript_word` rows.
    @discardableResult
    public static func replaceMeetingTranscript(
        segmentID: Int64,
        title: String,
        transcriptText: String,
        words: [LibreReverseTranscriptWordInput],
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64? {
        try validateTranscript(transcriptText: transcriptText, words: words)
        return try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                guard try segmentExists(segmentID, database: database) else {
                    throw LibreReverseLibraryStoreError.invalidTranscript(
                        "meeting segment does not exist: \(segmentID)"
                    )
                }
                let documentID = try replaceMeetingTranscript(
                    segmentID: segmentID,
                    title: title,
                    transcriptText: transcriptText,
                    words: words,
                    persistEmptyCompletionMarker: true,
                    database: database
                )
                try execute(database, "COMMIT")
                return documentID
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    /// Atomically renames a meeting that is still owned by the primary
    /// library. Transcript document and word identities remain stable; only
    /// the title projections used by the timeline, Calendar event, and ranked
    /// transcript search are changed.
    @discardableResult
    public static func updateMeetingTitle(
        segmentID: Int64,
        title: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTitle = normalized.isEmpty ? nil : normalized
        return try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var raw: OpaquePointer?
                try prepare(
                    database,
                    "UPDATE segment SET windowName=? WHERE id=? AND type=1",
                    &raw
                )
                var statement = try unwrap(raw, database)
                bindOptional(storedTitle, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, segmentID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                guard sqlite3_changes(database) == 1 else {
                    throw LibreReverseLibraryStoreError.invalidMeeting(
                        "meeting segment \(segmentID) is not present in the primary library"
                    )
                }

                raw = nil
                try prepare(database, "UPDATE event SET title=? WHERE segmentID=?", &raw)
                statement = try unwrap(raw, database)
                bindOptional(storedTitle, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, segmentID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)

                raw = nil
                try prepare(
                    database,
                    """
                    UPDATE searchRanking SET title=?
                     WHERE rowid IN (
                       SELECT docid FROM doc_segment
                        WHERE segmentId=? AND frameId IS NULL
                     )
                    """,
                    &raw
                )
                statement = try unwrap(raw, database)
                bind(storedTitle ?? "", to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, segmentID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)

                try execute(database, "COMMIT")
                return storedTitle
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func updateMeetingContext(
        segmentID: Int64,
        context: LibreReverseMeetingContextUpdate,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var raw: OpaquePointer?
                try prepare(
                    database,
                    """
                    SELECT e.detailsJSON FROM event e
                    JOIN segment s ON s.id=e.segmentID AND s.type=1
                    WHERE e.segmentID=?
                    """,
                    &raw
                )
                var statement = try unwrap(raw, database)
                sqlite3_bind_int64(statement, 1, segmentID)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    sqlite3_finalize(statement)
                    throw LibreReverseLibraryStoreError.invalidMeeting(
                        "meeting event \(segmentID) is not present in the primary library"
                    )
                }
                let existingDetails = optionalString(statement, column: 0)
                sqlite3_finalize(statement)

                var details: [String: Any] = [:]
                if let existingDetails,
                    let data = existingDetails.data(using: .utf8),
                    let decoded = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                {
                    details = decoded
                }
                if let calendarTitle = context.calendarTitle {
                    details["calendarTitle"] = calendarTitle
                } else {
                    details.removeValue(forKey: "calendarTitle")
                }
                let detailsJSON: String?
                if details.isEmpty {
                    detailsJSON = nil
                } else {
                    let data = try JSONSerialization.data(
                        withJSONObject: details,
                        options: [.sortedKeys]
                    )
                    detailsJSON = String(decoding: data, as: UTF8.self)
                }
                let participantsJSON: String?
                if context.participants.isEmpty {
                    participantsJSON = nil
                } else {
                    let data = try JSONSerialization.data(
                        withJSONObject: context.participants,
                        options: [.sortedKeys]
                    )
                    participantsJSON = String(decoding: data, as: UTF8.self)
                }

                raw = nil
                try prepare(
                    database,
                    "UPDATE event SET participants=?,detailsJSON=? WHERE segmentID=?",
                    &raw
                )
                statement = try unwrap(raw, database)
                bindOptional(participantsJSON, to: statement, index: 1)
                bindOptional(detailsJSON, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, segmentID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
                guard sqlite3_changes(database) == 1 else {
                    throw LibreReverseLibraryStoreError.invalidMeeting(
                        "meeting event \(segmentID) is not present in the primary library"
                    )
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private static func validateMeeting(_ meeting: LibreReverseMeetingPublication) throws {
        guard meeting.endDate > meeting.startDate,
            meeting.duration > 0,
            meeting.width > 0,
            meeting.height > 0,
            meeting.frameRate > 0
        else {
            throw LibreReverseLibraryStoreError.invalidMeeting(
                "meeting dates, duration, dimensions, and frame rate must be positive"
            )
        }
        guard isSafeRelativePath(meeting.relativeMediaPath),
            VideoStorage.isCanonicalRelativePath(
                meeting.relativeMediaPath,
                xid: meeting.xid
            )
        else {
            throw LibreReverseLibraryStoreError.invalidMediaPath(meeting.relativeMediaPath)
        }
        if let event = meeting.event,
            event.type.isEmpty || event.status.isEmpty
        {
            throw LibreReverseLibraryStoreError.invalidMeeting(
                "event type and status must be non-empty"
            )
        }
        try validateTranscript(
            transcriptText: meeting.transcriptText,
            words: meeting.transcriptWords
        )
    }

    private static func validateTranscript(
        transcriptText: String,
        words: [LibreReverseTranscriptWordInput]
    ) throws {
        let utf16Count = transcriptText.utf16.count
        var previousTimeOffset = -1
        var previousFullTextOffset = -1
        for word in words {
            guard !word.speechSource.isEmpty,
                !word.word.isEmpty,
                word.timeOffset >= 0,
                word.duration >= 0,
                word.timeOffset >= previousTimeOffset
            else {
                throw LibreReverseLibraryStoreError.invalidTranscript(
                    "words require non-empty source/text and nondecreasing nonnegative timing"
                )
            }
            if let offset = word.fullTextOffset {
                guard offset >= previousFullTextOffset,
                    offset >= 0,
                    offset <= utf16Count
                else {
                    throw LibreReverseLibraryStoreError.invalidTranscript(
                        "full-text offsets must be ordered UTF-16 positions inside transcript text"
                    )
                }
                previousFullTextOffset = offset
            }
            previousTimeOffset = word.timeOffset
        }
        if !words.isEmpty && transcriptText.isEmpty {
            throw LibreReverseLibraryStoreError.invalidTranscript(
                "finalized transcript words require searchable transcript text"
            )
        }
    }

    private static func segmentExists(
        _ segmentID: Int64,
        database: OpaquePointer
    ) throws -> Bool {
        var raw: OpaquePointer?
        try prepare(database, "SELECT 1 FROM segment WHERE id=? AND type=1", &raw)
        let statement = try unwrap(raw, database)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, segmentID)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func replaceMeetingTranscript(
        segmentID: Int64,
        title: String,
        transcriptText: String,
        words: [LibreReverseTranscriptWordInput],
        persistEmptyCompletionMarker: Bool = false,
        database: OpaquePointer
    ) throws -> Int64? {
        try validateTranscript(transcriptText: transcriptText, words: words)
        var raw: OpaquePointer?
        try prepare(
            database,
            "SELECT docid FROM doc_segment WHERE segmentId=? AND frameId IS NULL",
            &raw
        )
        var statement = try unwrap(raw, database)
        sqlite3_bind_int64(statement, 1, segmentID)
        var documentIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            documentIDs.append(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)

        raw = nil
        try prepare(
            database,
            "DELETE FROM doc_segment WHERE segmentId=? AND frameId IS NULL",
            &raw
        )
        statement = try unwrap(raw, database)
        sqlite3_bind_int64(statement, 1, segmentID)
        try stepDone(statement, database)
        sqlite3_finalize(statement)
        for documentID in documentIDs {
            for table in ["searchRanking", "search", "searchOffsets"] {
                raw = nil
                try prepare(database, "DELETE FROM \(table) WHERE rowid=?", &raw)
                statement = try unwrap(raw, database)
                sqlite3_bind_int64(statement, 1, documentID)
                try stepDone(statement, database)
                sqlite3_finalize(statement)
            }
        }

        raw = nil
        try prepare(database, "DELETE FROM transcript_word WHERE segmentId=?", &raw)
        statement = try unwrap(raw, database)
        sqlite3_bind_int64(statement, 1, segmentID)
        try stepDone(statement, database)
        sqlite3_finalize(statement)

        raw = nil
        try prepare(
            database,
            """
            INSERT INTO transcript_word(
              segmentId,speechSource,word,timeOffset,fullTextOffset,duration
            ) VALUES(?,?,?,?,?,?)
            """, &raw)
        statement = try unwrap(raw, database)
        for word in words {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, segmentID)
            bind(word.speechSource, to: statement, index: 2)
            bind(word.word, to: statement, index: 3)
            sqlite3_bind_int64(statement, 4, Int64(word.timeOffset))
            if let fullTextOffset = word.fullTextOffset {
                sqlite3_bind_int64(statement, 5, Int64(fullTextOffset))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_int64(statement, 6, Int64(word.duration))
            try stepDone(statement, database)
        }
        sqlite3_finalize(statement)

        guard !transcriptText.isEmpty || persistEmptyCompletionMarker else { return nil }
        let documentID = try documentIDs.first ?? allocateDocumentID(database)
        raw = nil
        try prepare(
            database,
            "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(?,?,?,?)",
            &raw
        )
        statement = try unwrap(raw, database)
        sqlite3_bind_int64(statement, 1, documentID)
        bind(transcriptText, to: statement, index: 2)
        bind("", to: statement, index: 3)
        bind(title, to: statement, index: 4)
        try stepDone(statement, database)
        sqlite3_finalize(statement)

        for table in ["search", "searchOffsets"] {
            raw = nil
            try prepare(
                database,
                "INSERT INTO \(table)(rowid,text,otherText) VALUES(?,?,?)",
                &raw
            )
            statement = try unwrap(raw, database)
            sqlite3_bind_int64(statement, 1, documentID)
            bind(transcriptText, to: statement, index: 2)
            bind("", to: statement, index: 3)
            try stepDone(statement, database)
            sqlite3_finalize(statement)
        }

        raw = nil
        try prepare(
            database,
            "INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(?,?,NULL)",
            &raw
        )
        statement = try unwrap(raw, database)
        sqlite3_bind_int64(statement, 1, documentID)
        sqlite3_bind_int64(statement, 2, segmentID)
        try stepDone(statement, database)
        sqlite3_finalize(statement)
        return documentID
    }

    private struct CurrentCapturedScreenSegment {
        let id: Int64
        let startDate: Date
        let endDate: Date
        let context: LibreReverseCaptureContext?
    }

    private static func timelineSegment(
        id: Int64,
        startDate: Date,
        endDate: Date,
        context: LibreReverseCaptureContext?
    ) -> TimelineSegment {
        TimelineSegment(
            startDate: startDate,
            endDate: endDate,
            bundleID: context?.bundleID,
            windowName: context?.windowName,
            browserURL: context?.browserURL,
            browserProfile: context?.browserProfile,
            rawID: id,
            rawType: .capturedScreen
        )
    }

    private static func currentCapturedScreenSegment(
        _ database: OpaquePointer
    ) throws -> CurrentCapturedScreenSegment? {
        var raw: OpaquePointer?
        try prepare(
            database,
            """
            SELECT id,startDate,endDate,bundleID,windowName,browserUrl,browserProfile
              FROM segment WHERE type=0 ORDER BY startDate DESC LIMIT 1
            """, &raw)
        let statement = try unwrap(raw, database)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
            let startDate = databaseDateFormatter.date(
                from: String(cString: sqlite3_column_text(statement, 1))
            ),
            let endDate = databaseDateFormatter.date(
                from: String(cString: sqlite3_column_text(statement, 2))
            )
        else {
            throw sqliteError(database)
        }
        let context: LibreReverseCaptureContext? =
            sqlite3_column_type(statement, 3) == SQLITE_NULL
                && sqlite3_column_type(statement, 4) == SQLITE_NULL
                && sqlite3_column_type(statement, 5) == SQLITE_NULL
                && sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : LibreReverseCaptureContext(
                bundleID: optionalString(statement, column: 3),
                windowName: optionalString(statement, column: 4),
                browserURL: optionalString(statement, column: 5),
                browserProfile: optionalString(statement, column: 6)
            )
        return CurrentCapturedScreenSegment(
            id: sqlite3_column_int64(statement, 0),
            startDate: startDate,
            endDate: endDate,
            context: context
        )
    }

    private static func insertCapturedScreenSegment(
        createdAt: Date,
        context: LibreReverseCaptureContext?,
        database: OpaquePointer
    ) throws -> Int64 {
        var raw: OpaquePointer?
        try prepare(
            database,
            """
            INSERT INTO segment(bundleID,startDate,endDate,windowName,browserUrl,browserProfile,type)
            VALUES(?,?,?,?,?,?,0)
            """, &raw)
        let statement = try unwrap(raw, database)
        defer { sqlite3_finalize(statement) }
        bindOptional(context?.bundleID, to: statement, index: 1)
        bind(databaseDate(createdAt), to: statement, index: 2)
        bind(
            databaseDate(
                createdAt.addingTimeInterval(
                    CaptureContract.productionCaptureIntervalSeconds
                )),
            to: statement,
            index: 3
        )
        bindOptional(context?.windowName, to: statement, index: 4)
        bindOptional(context?.browserURL, to: statement, index: 5)
        bindOptional(context?.browserProfile, to: statement, index: 6)
        try stepDone(statement, database)
        return sqlite3_last_insert_rowid(database)
    }

    private static func updateSegmentEnd(
        id: Int64,
        endDate: Date,
        database: OpaquePointer
    ) throws {
        var raw: OpaquePointer?
        try prepare(database, "UPDATE segment SET endDate=? WHERE id=?", &raw)
        let statement = try unwrap(raw, database)
        defer { sqlite3_finalize(statement) }
        bind(databaseDate(endDate), to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, id)
        try stepDone(statement, database)
        guard sqlite3_changes(database) == 1 else {
            throw LibreReverseLibraryStoreError.sqlite("segment not found: \(id)")
        }
    }

    private static func withDatabase<T>(
        _ configuration: LibreReverseLibraryConfiguration,
        create: Bool,
        session: LibreReverseLibraryWriteSession? = nil,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        if let session {
            return try session.withDatabase(configuration: configuration, operation: operation)
        }
        let database = try openWriteDatabase(configuration, create: create)
        defer { sqlite3_close(database) }
        return try operation(database)
    }

    static func openWriteDatabase(
        _ configuration: LibreReverseLibraryConfiguration,
        create: Bool
    ) throws -> OpaquePointer {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("DatabaseOpen", id: signposter.makeSignpostID())
        defer { signposter.endInterval("DatabaseOpen", interval) }
        try LibreReverseLibraryKey.validate(configuration.keyFileURL)
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(configuration.databaseURL.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage) ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LibreReverseLibraryStoreError.unableToOpenDatabase(message)
        }
        do {
            let keyStatus = key.withUnsafeBytes {
                sqlite3_key(database, $0.baseAddress, Int32($0.count))
            }
            guard keyStatus == SQLITE_OK else {
                throw LibreReverseLibraryStoreError.unableToApplyKey(keyStatus)
            }
            try execute(database,
                "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON")
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func databaseDate(_ date: Date) -> String {
        databaseDateFormatter.string(from: date)
    }

    // Shard metadata uses an explicit UTC offset; frame timestamps retain the
    // legacy timezone-free representation. Accept both metadata generations.
    private static func parseShardEpoch(_ text: String) -> Date? {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value.date(from: text)
    }

    private static let databaseDateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .iso8601)
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return value
    }()

    private static func prepare(
        _ database: OpaquePointer,
        _ sql: String,
        _ statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private static func unwrap(
        _ statement: OpaquePointer?,
        _ database: OpaquePointer
    ) throws -> OpaquePointer {
        guard let statement else { throw sqliteError(database) }
        return statement
    }

    private static func stepDone(_ statement: OpaquePointer, _ database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func bindOptional(
        _ value: String?,
        to statement: OpaquePointer,
        index: Int32
    ) {
        if let value {
            bind(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func optionalString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: text)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(error)
            throw LibreReverseLibraryStoreError.sqlite(message)
        }
    }

    private static func sqliteError(_ database: OpaquePointer) -> LibreReverseLibraryStoreError {
        .sqlite(errorMessage(database))
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}

public struct LibreReverseMeetingSummaryJob: Sendable {
    public let eventID: Int64
    public let segmentID: Int64
    public let transcript: String
}

extension LibreReverseLibraryStore {
    public static func enqueueMeetingSummary(segmentID: Int64, configuration: LibreReverseLibraryConfiguration) throws {
        try withDatabase(configuration, create: false) { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { try? execute(db, "ROLLBACK") }
            var raw: OpaquePointer?
            try prepare(db, "INSERT INTO event(type,status,title,segmentID) SELECT 'meeting','completed',windowName,id FROM segment s WHERE id=? AND type=1 AND NOT EXISTS(SELECT 1 FROM event WHERE segmentID=s.id)", &raw)
            let event = try unwrap(raw, db)
            sqlite3_bind_int64(event, 1, segmentID)
            do { try stepDone(event, db) } catch { sqlite3_finalize(event); throw error }
            sqlite3_finalize(event)
            raw = nil
            try prepare(db, "INSERT OR IGNORE INTO summary(status,eventId) SELECT 'localQueued',MIN(id) FROM event WHERE segmentID=? HAVING COUNT(*)>0", &raw)
            let statement = try unwrap(raw, db)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, segmentID)
            try stepDone(statement, db)
            try execute(db, "COMMIT")
        }
    }

    public static func pendingMeetingSummaries(configuration: LibreReverseLibraryConfiguration, now: Date = Date(), session: LibreReverseLibraryWriteSession? = nil) throws -> [LibreReverseMeetingSummaryJob] {
        try withDatabase(configuration, create: false, session: session) { db in
            var raw: OpaquePointer?
            try prepare(db, """
                SELECT e.id,e.segmentID,r.text FROM summary sm
                JOIN event e ON e.id=sm.eventId
                LEFT JOIN doc_segment ds ON ds.segmentId=e.segmentID AND ds.frameId IS NULL
                LEFT JOIN searchRanking r ON r.rowid=ds.docid
                LEFT JOIN librereverse_summary_retry retry ON retry.eventID=e.id
                WHERE sm.status IN ('localQueued','localRetrying')
                  AND (retry.retryAfter IS NULL OR retry.retryAfter<=?)
                ORDER BY COALESCE(retry.retryAfter,0),e.id LIMIT 8
                """, &raw)
            let statement = try unwrap(raw, db)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            var result: [LibreReverseMeetingSummaryJob] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                result.append(.init(eventID: sqlite3_column_int64(statement, 0),
                    segmentID: sqlite3_column_int64(statement, 1),
                    transcript: optionalString(statement, column: 2) ?? ""))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw sqliteError(db) }
            return result
        }
    }

    public static func finishMeetingSummary(eventID: Int64, text: String?, configuration: LibreReverseLibraryConfiguration, isLocal: Bool = true, now: Date = Date(), session: LibreReverseLibraryWriteSession? = nil) throws {
        try withDatabase(configuration, create: false, session: session) { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { try? execute(db, "ROLLBACK") }
            var raw: OpaquePointer?
            try prepare(db, "UPDATE summary SET status=?,text=? WHERE eventId=? AND status IN ('localQueued','localRetrying')", &raw)
            let statement = try unwrap(raw, db)
            defer { sqlite3_finalize(statement) }
            bind(text == nil ? "localRetrying" : (isLocal ? "localComplete" : "complete"), to: statement, index: 1)
            bindOptional(text, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, eventID)
            try stepDone(statement, db)
            if sqlite3_changes(db) > 0 {
                raw = nil
                if text == nil {
                    // Start at one minute (including unavailable providers),
                    // double each failure, and keep retrying at most hourly.
                    try prepare(db, """
                        INSERT INTO librereverse_summary_retry(eventID,attempts,retryAfter)
                        VALUES(?,1,?+60)
                        ON CONFLICT(eventID) DO UPDATE SET
                          attempts=MIN(attempts+1,2147483647),
                          retryAfter=?+MIN(3600,60*(1 << MIN(attempts,6)))
                        """, &raw)
                } else {
                    try prepare(db, "DELETE FROM librereverse_summary_retry WHERE eventID=?", &raw)
                }
                let retry = try unwrap(raw, db)
                defer { sqlite3_finalize(retry) }
                sqlite3_bind_int64(retry, 1, eventID)
                if text == nil {
                    sqlite3_bind_double(retry, 2, now.timeIntervalSince1970)
                    sqlite3_bind_double(retry, 3, now.timeIntervalSince1970)
                }
                try stepDone(retry, db)
            }
            try execute(db, "COMMIT")
        }
    }
}
#endif
