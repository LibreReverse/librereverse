#if os(macOS)
import CSQLCipher
import Foundation

public struct HistoricalSearchValidationInventory: Equatable, Sendable {
    public let searchableDocumentCount: Int
    public let transcriptDocumentCount: Int
    public let starredFrameCount: Int
    public let locallyResidentShardCount: Int
    public let unavailableShardCount: Int

    public init(
        searchableDocumentCount: Int,
        transcriptDocumentCount: Int,
        starredFrameCount: Int,
        locallyResidentShardCount: Int,
        unavailableShardCount: Int
    ) {
        self.searchableDocumentCount = searchableDocumentCount
        self.transcriptDocumentCount = transcriptDocumentCount
        self.starredFrameCount = starredFrameCount
        self.locallyResidentShardCount = locallyResidentShardCount
        self.unavailableShardCount = unavailableShardCount
    }
}

/// A catalog-only description of history whose immutable database shard is
/// not currently resident. It contains no captured content and is cheap to
/// cache beside the timeline so an archived seek can be surfaced immediately.
public struct HistoricalUnavailableShard: Equatable, Sendable {
    public let ordinal: Int64
    public let interval: LibreReverseShardInterval

    public init(ordinal: Int64, interval: LibreReverseShardInterval) {
        self.ordinal = ordinal
        self.interval = interval
    }
}

/// A long-lived keyed database connection.
///
/// SQLCipher key derivation runs once per connection, and prepared statements
/// are reused across seeks. Actor isolation serializes queries off the main
/// thread so database work does not block explorer interactions.
public actor LibraryDatabaseSession {
    private struct ShardDescriptor {
        let id: Int64
        let ordinal: Int64
        let interval: LibreReverseShardInterval
        let relativePath: String?
        let state: LibreReverseShardState
        let frameCount: Int64
    }

    private final class ShardConnection {
        let database: OpaquePointer
        var before: OpaquePointer?
        var after: OpaquePointer?

        init(database: OpaquePointer) { self.database = database }

        func close() {
        if let before {
          sqlite3_finalize(before)
          self.before = nil
        }
        if let after {
          sqlite3_finalize(after)
          self.after = nil
        }
            sqlite3_close(database)
        }
    }

    private let configuration: LibraryDatabaseConfiguration
    private var connection: OpaquePointer?
    private var momentAtOrBeforeStatement: OpaquePointer?
    private var momentAfterStatement: OpaquePointer?
    private var shardDescriptors: [ShardDescriptor]?
    private var shardConnections: [Int64: ShardConnection] = [:]
    private var shardLRU: [Int64] = []
    /// Sized to hold every locally sealed shard at once.
    ///
    /// The node lookups sweep the sealed shards in ordinal order, so a cache
    /// smaller than the shard count has a zero percent hit rate on that sweep:
    /// each pass evicts exactly the entries the next pass reads first. With
    /// ten sealed shards against a capacity of five, a single search reopened
    /// multi-gigabyte SQLCipher databases hundreds of times -- each one paying
    /// full key derivation -- and never finished.
    private let shardConnectionCapacity = 16

    /// Records connection and disconnection times.
    public private(set) var connectedAt: Date?
    public private(set) var disconnectedAt: Date?

    public var hasConnection: Bool { connection != nil }

    public init(configuration: LibraryDatabaseConfiguration) {
        self.configuration = configuration
    }

    deinit {
        if let momentAtOrBeforeStatement { sqlite3_finalize(momentAtOrBeforeStatement) }
        if let momentAfterStatement { sqlite3_finalize(momentAfterStatement) }
        if let connection { sqlite3_close(connection) }
        for shard in shardConnections.values { shard.close() }
    }

    /// Opens the connection if it is not already open. Safe to call repeatedly.
    @discardableResult
    public func connect() throws -> OpaquePointer {
        if let connection { return connection }
        let opened = try LibraryDatabase.openKeyedDatabase(
            configuration: configuration
        )
        connection = opened
        connectedAt = Date()
        disconnectedAt = nil
        return opened
    }

    public func closeConnection() {
        if let momentAtOrBeforeStatement {
            sqlite3_finalize(momentAtOrBeforeStatement)
            self.momentAtOrBeforeStatement = nil
        }
        if let momentAfterStatement {
            sqlite3_finalize(momentAfterStatement)
            self.momentAfterStatement = nil
        }
        if let connection {
            sqlite3_close(connection)
            self.connection = nil
            disconnectedAt = Date()
        }
        for shard in shardConnections.values { shard.close() }
        shardConnections.removeAll()
        shardLRU.removeAll()
        shardDescriptors = nil
    }

    /// Invalidates only immutable-shard routing state after an atomic
    /// rehydration install. The compact primary connection and its prepared
    /// statements stay warm, while the next seek observes the new residency.
    public func reloadShardCatalog() {
        for shard in shardConnections.values { shard.close() }
        shardConnections.removeAll()
        shardLRU.removeAll()
        shardDescriptors = nil
    }

    /// Returns only non-local shard boundaries. Keeping this catalog beside
    /// the UI avoids waiting for a frame query to fail before offering the
    /// user an archive download.
    public func unavailableShards() throws -> [HistoricalUnavailableShard] {
        let database = try connect()
        guard try isSharded(database) else { return [] }
        return try loadShardDescriptors(database).compactMap { descriptor in
            guard descriptor.state != .sealedLocal else { return nil }
            return HistoricalUnavailableShard(
                ordinal: descriptor.ordinal,
                interval: descriptor.interval
            )
        }
    }

    /// Resolves the canonical nearest frame, preferring the later frame on a tie.
    public func nearestMoment(to date: Date) throws -> HistoricalTimelineMoment? {
        let database = try connect()
        guard try isSharded(database) else {
            return try nearestMoment(to: date, database: database)
        }
        let descriptors = try loadShardDescriptors(database)
        if let containing = descriptors.first(where: { $0.interval.contains(date) }),
        containing.state != .sealedLocal
      {
            throw LibraryDatabaseError.shardUnavailable(
                ordinal: containing.ordinal,
                state: containing.state.rawValue
            )
        }

        var beforeCandidates: [HistoricalTimelineMoment] = []
        var afterCandidates: [HistoricalTimelineMoment] = []
        if let value = try candidate(
            statement: try preparedMomentAtOrBeforeStatement(database),
            date: date,
            database: database
      ) {
        beforeCandidates.append(value)
      }
        if let value = try candidate(
            statement: try preparedMomentAfterStatement(database),
            date: date,
            database: database
      ) {
        afterCandidates.append(value)
      }

        for descriptor in relevantDescriptors(for: date, descriptors: descriptors) {
            guard descriptor.state == .sealedLocal else { continue }
            let shard = try shardConnection(for: descriptor)
            if let value = try candidate(
                statement: try preparedBeforeStatement(shard),
                date: date,
                database: shard.database
        ) {
          beforeCandidates.append(value)
        }
            if let value = try candidate(
                statement: try preparedAfterStatement(shard),
                date: date,
                database: shard.database
        ) {
          afterCandidates.append(value)
        }
        }

        let before = beforeCandidates.max(by: { $0.wallDate < $1.wallDate })
        let after = afterCandidates.min(by: { $0.wallDate < $1.wallDate })
        switch (before, after) {
        case (nil, let after?): return after
        case (let before?, nil): return before
        case (nil, nil): return nil
        case (let before?, let after?):
            return abs(date.timeIntervalSince(before.wallDate))
                < abs(date.timeIntervalSince(after.wallDate)) ? before : after
        }
    }

    /// Resolves a playable approximation using only compact catalog rows that
    /// remain in the primary database after frame payloads move to a remote
    /// shard. This lets an archived-hour request identify and restore its MP4
    /// without downloading the multi-gigabyte SQLCipher shard first.
    public func catalogMoment(to date: Date) throws -> HistoricalTimelineMoment? {
        let database = try connect()
        let encoded = LibraryDatabase.databaseString(date)
        let sql = """
            SELECT v.id,v.path,v.width,v.height,v.frameRate,
                   b.minCreatedAt,b.maxCreatedAt,b.frameCount
              FROM video_frame_bounds b JOIN video v ON v.id=b.videoId
             ORDER BY CASE
               WHEN b.minCreatedAt<=? AND b.maxCreatedAt>=? THEN 0
               WHEN b.maxCreatedAt<? THEN julianday(?) - julianday(b.maxCreatedAt)
               ELSE julianday(b.minCreatedAt) - julianday(?) END,
               b.videoId
             LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for index in 1...5 {
            sqlite3_bind_text(statement, Int32(index), encoded, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let videoID = sqlite3_column_int64(statement, 0)
        let path = LibraryDatabase.string(statement, column: 1) ?? ""
        let width = Int(sqlite3_column_int64(statement, 2))
        let height = Int(sqlite3_column_int64(statement, 3))
        let frameRate = sqlite3_column_double(statement, 4)
        guard let minValue = LibraryDatabase.string(statement, column: 5),
              let maxValue = LibraryDatabase.string(statement, column: 6)
        else { return nil }
        let minimum = try LibraryDatabase.databaseDate(minValue)
        let maximum = try LibraryDatabase.databaseDate(maxValue)
        let wallDate = min(max(date, minimum), maximum)
        let frameIndex = max(0, Int((wallDate.timeIntervalSince(minimum) * frameRate).rounded()))

        var segmentStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id,bundleID,startDate,endDate,windowName,browserUrl,type FROM segment WHERE startDate<=? AND endDate>=? ORDER BY startDate DESC,id DESC LIMIT 1",
            -1,
            &segmentStatement,
            nil
        ) == SQLITE_OK, let segmentStatement else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(segmentStatement) }
        sqlite3_bind_text(segmentStatement, 1, encoded, -1, transient)
        sqlite3_bind_text(segmentStatement, 2, encoded, -1, transient)
        let hasSegment = sqlite3_step(segmentStatement) == SQLITE_ROW
        let segmentStart = hasSegment
            ? LibraryDatabase.string(segmentStatement, column: 2).flatMap {
                try? LibraryDatabase.databaseDate($0)
            }
            : nil
        let segmentEnd = hasSegment
            ? LibraryDatabase.string(segmentStatement, column: 3).flatMap {
                try? LibraryDatabase.databaseDate($0)
            }
            : nil
        return HistoricalTimelineMoment(
            frameID: -videoID,
            wallDate: wallDate,
            databaseVideoID: videoID,
            chunkURL: configuration.mediaRoot.appendingPathComponent(path),
            frameImageURL: configuration.frameImagesRoot.appendingPathComponent(
                "archived-catalog-\(videoID).png"
            ),
            mediaTime: frameRate > 0 ? Double(frameIndex) / frameRate : nil,
            videoFrameIndex: frameRate > 0 ? frameIndex : nil,
            videoFrameRate: frameRate,
            videoWidth: width,
            videoHeight: height,
            segmentID: hasSegment ? sqlite3_column_int64(segmentStatement, 0) : nil,
            bundleID: hasSegment
                ? LibraryDatabase.string(segmentStatement, column: 1) : nil,
            segmentStartDate: segmentStart,
            segmentEndDate: segmentEnd,
            windowName: hasSegment
                ? LibraryDatabase.string(segmentStatement, column: 4) : nil,
            browserURL: hasSegment
                ? LibraryDatabase.string(segmentStatement, column: 5) : nil,
            segmentType: hasSegment ? Int(sqlite3_column_int64(segmentStatement, 6)) : nil,
            isStarred: false,
            isPendingImage: false
        )
    }

    /// Resolves the durable video anchor for one audio/meeting segment. This
    /// avoids a transcript seek accidentally selecting a nearby screenshot
    /// frame from the independently rendered captured-screen track.
    public func meetingMoment(
      segmentID: Int64,
      at date: Date
    ) throws -> HistoricalTimelineMoment? {
      let database = try connect()
      if let moment = try meetingMoment(segmentID: segmentID, database: database) {
        return moment
      }
      if try isSharded(database),
        let descriptor = try loadShardDescriptors(database).first(where: {
          $0.state == .sealedLocal && $0.interval.contains(date)
        })
      {
        return try meetingMoment(
          segmentID: segmentID,
          database: try shardConnection(for: descriptor).database
        )
      }
      return nil
    }

    public func meetingTranscript(
      segmentID: Int64,
      at date: Date
    ) throws -> LibreReverseMeetingTranscript? {
      let database = try connect()
      let catalogTranscript = try meetingTranscript(segmentID: segmentID, database: database)
      if try isSharded(database),
        let descriptor = try loadShardDescriptors(database).first(where: {
          $0.state == .sealedLocal && $0.interval.contains(date)
        })
      {
        if let payloadTranscript = try meetingTranscript(
          segmentID: segmentID,
          database: try shardConnection(for: descriptor).database
        ) {
          guard let catalogTranscript else { return payloadTranscript }
          return .init(
            segmentID: payloadTranscript.segmentID,
            title: catalogTranscript.title,
            text: payloadTranscript.text,
            startDate: payloadTranscript.startDate,
            endDate: payloadTranscript.endDate,
            words: payloadTranscript.words,
            metadata: catalogTranscript.metadata,
            processingState: payloadTranscript.processingState
          )
        }
      }
      return catalogTranscript
    }

    private func meetingTranscript(
      segmentID: Int64,
      database: OpaquePointer
    ) throws -> LibreReverseMeetingTranscript? {
      // Sealed payload shards omit mutable event metadata; the primary catalog
      // supplies it when the transcript is assembled for presentation.
      let hasEventTable = try hasTable("event", database: database)
      let eventColumns =
        hasEventTable
        ? "e.participants,e.detailsJSON,e.calendarID,e.calendarEventID,e.calendarSeriesID"
        : "NULL,NULL,NULL,NULL,NULL"
      let eventJoin =
        hasEventTable
        ? "LEFT JOIN event e ON e.id=(SELECT MIN(id) FROM event WHERE segmentID=s.id)"
        : ""
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database,
          """
          SELECT s.startDate,s.endDate,COALESCE(s.windowName,''),
                 COALESCE((SELECT r.text FROM doc_segment ds
                           JOIN searchRanking r ON r.rowid=ds.docid
                          WHERE ds.segmentId=s.id AND ds.frameId IS NULL LIMIT 1),''),
                 EXISTS(SELECT 1 FROM doc_segment ds
                         WHERE ds.segmentId=s.id AND ds.frameId IS NULL),
                 \(eventColumns),
                 w.id,w.speechSource,w.word,w.timeOffset,w.duration,w.fullTextOffset
            FROM segment s
            \(eventJoin)
            LEFT JOIN transcript_word w ON w.segmentId=s.id
           WHERE s.id=? AND s.type=1
           ORDER BY w.timeOffset,w.id
          """, -1, &statement, nil) == SQLITE_OK, let statement
      else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, segmentID)
      var startDate: Date?
      var endDate: Date?
      var title = ""
      var text = ""
      var transcriptPersisted = false
      var metadata = LibreReverseMeetingTranscriptMetadata()
      var words: [LibreReverseMeetingTranscriptWord] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW else {
          throw LibraryDatabaseError.queryFailed(
            LibraryDatabase.errorMessage(database)
          )
        }
        if startDate == nil {
          startDate = try LibraryDatabase.databaseDate(
            LibraryDatabase.string(statement, column: 0) ?? ""
          )
          endDate = try LibraryDatabase.databaseDate(
            LibraryDatabase.string(statement, column: 1) ?? ""
          )
          title = LibraryDatabase.string(statement, column: 2) ?? ""
          text = LibraryDatabase.string(statement, column: 3) ?? ""
          transcriptPersisted = sqlite3_column_int(statement, 4) != 0
          metadata = Self.meetingTranscriptMetadata(
            participantsJSON: LibraryDatabase.string(statement, column: 5),
            detailsJSON: LibraryDatabase.string(statement, column: 6),
            calendarID: LibraryDatabase.string(statement, column: 7),
            calendarEventID: LibraryDatabase.string(statement, column: 8),
            calendarSeriesID: LibraryDatabase.string(statement, column: 9)
          )
        }
        guard sqlite3_column_type(statement, 10) != SQLITE_NULL else { continue }
        words.append(
          .init(
            id: sqlite3_column_int64(statement, 10),
            speechSource: LibraryDatabase.string(statement, column: 11)
              ?? "unknown",
            text: LibraryDatabase.string(statement, column: 12) ?? "",
            startSeconds: TimeInterval(sqlite3_column_int64(statement, 13)),
            durationSeconds: TimeInterval(sqlite3_column_int64(statement, 14)),
            fullTextUTF16Offset: LibraryDatabase.optionalInt(
              statement,
              column: 15
            )
          ))
      }
      guard let startDate, let endDate else { return nil }
      return .init(
        segmentID: segmentID,
        title: title,
        text: text,
        startDate: startDate,
        endDate: endDate,
        words: words,
        metadata: metadata,
        processingState: transcriptPersisted ? .complete : .unavailable
      )
    }

    private static func meetingTranscriptMetadata(
      participantsJSON: String?,
      detailsJSON: String?,
      calendarID: String?,
      calendarEventID: String?,
      calendarSeriesID: String?
    ) -> LibreReverseMeetingTranscriptMetadata {
      let details: [String: Any]
      if let detailsJSON,
        let data = detailsJSON.data(using: .utf8),
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        details = decoded
      } else {
        details = [:]
      }
      let participants: [String]
      if let participantsJSON,
        let data = participantsJSON.data(using: .utf8),
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
      {
        participants = decoded.compactMap { value in
          guard let name = value as? String else { return nil }
          let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
          return normalized.isEmpty ? nil : normalized
        }
      } else {
        participants = []
      }
      return .init(
        provider: (details["provider"] as? String).flatMap {
          LibreReverseMeetingProvider(persistedValue: $0)
        },
        source: (details["source"] as? String).flatMap(
          LibreReverseMeetingCandidateSource.init),
        calendarTitle: details["calendarTitle"] as? String,
        participants: participants,
        calendarID: calendarID,
        calendarEventID: calendarEventID,
        calendarSeriesID: calendarSeriesID
      )
    }

    private func meetingMoment(
      segmentID: Int64,
      database: OpaquePointer
    ) throws -> HistoricalTimelineMoment? {
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database,
          LibraryDatabase.meetingMomentSQL,
          -1,
          &statement,
          nil
        ) == SQLITE_OK, let statement
      else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, segmentID)
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return nil }
      guard status == SQLITE_ROW else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      return try LibraryDatabase.decodeMoment(
        statement,
        configuration: configuration
      )
    }

    private func nearestMoment(
        to date: Date,
        database: OpaquePointer
    ) throws -> HistoricalTimelineMoment? {
        let before = try candidate(
            statement: try preparedMomentAtOrBeforeStatement(database),
            date: date,
            database: database
        )
        if before?.wallDate == date { return before }
        let after = try candidate(
            statement: try preparedMomentAfterStatement(database),
            date: date,
            database: database
        )
        switch (before, after) {
        case (nil, let after?): return after
        case (let before?, nil): return before
        case (nil, nil): return nil
        case (let before?, let after?):
            return abs(date.timeIntervalSince(before.wallDate))
                < abs(date.timeIntervalSince(after.wallDate)) ? before : after
        }
    }

    /// Strictly adjacent frame in wall-clock order for deterministic
    /// frame-by-frame stepping.
    public func neighbourMoment(
        of date: Date,
        forward: Bool
    ) throws -> HistoricalTimelineMoment? {
        let database = try connect()
        if try isSharded(database) {
            let descriptors = try loadShardDescriptors(database)
            if let containing = descriptors.first(where: { $0.interval.contains(date) }),
          containing.state != .sealedLocal
        {
                throw LibraryDatabaseError.shardUnavailable(
                    ordinal: containing.ordinal,
                    state: containing.state.rawValue
                )
            }
            let probe = forward ? date : date.addingTimeInterval(-0.001)
            var candidates: [HistoricalTimelineMoment] = []
            if let value = try candidate(
                statement: forward
                    ? try preparedMomentAfterStatement(database)
                    : try preparedMomentAtOrBeforeStatement(database),
                date: probe,
                database: database
        ) {
          candidates.append(value)
        }
            for descriptor in relevantDescriptors(for: date, descriptors: descriptors)
            where descriptor.state == .sealedLocal {
                let shard = try shardConnection(for: descriptor)
                if let value = try candidate(
                    statement: forward
                        ? try preparedAfterStatement(shard)
                        : try preparedBeforeStatement(shard),
                    date: probe,
                    database: shard.database
          ) {
            candidates.append(value)
          }
            }
            return forward
                ? candidates.min(by: { $0.wallDate < $1.wallDate })
                : candidates.max(by: { $0.wallDate < $1.wallDate })
        }
        if forward {
            return try candidate(
                statement: try preparedMomentAfterStatement(database),
                date: date,
                database: database
            )
        }
        // `preparedMomentAtOrBeforeStatement` is `createdAt <= ?`, so step the
        // probe back by one millisecond — the stored resolution — to make it
        // strictly earlier than the current frame.
        return try candidate(
            statement: try preparedMomentAtOrBeforeStatement(database),
            date: date.addingTimeInterval(-0.001),
            database: database
        )
    }

    private func candidate(
        statement: OpaquePointer,
        date: Date,
        database: OpaquePointer
    ) throws -> HistoricalTimelineMoment? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        // A prepared SELECT left at SQLITE_ROW keeps the connection's implicit
        // read transaction open. Because the timeline window queries share
        // this connection, that also pins them to the WAL snapshot observed by
        // the last frame lookup. Always finish the statement before another
        // actor-isolated operation can use the connection.
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(
            statement, 1, LibraryDatabase.databaseString(date), -1, transient
        )
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        return try LibraryDatabase.decodeMoment(
            statement, configuration: configuration
        )
    }

    /// Loads the canonical newest-duration window over the persistent
    /// connection.
    public func recentTimelineWindow(
        duration: TimeInterval = LibraryDatabase.initialTimelineWindowDuration,
        includesPlaybackTiming: Bool = false
    ) throws -> HistoricalTimelineSegmentWindow {
        let database = try connect()
        let window = try LibraryDatabase.loadRecentTimelineWindow(
            database: database,
            duration: duration
        )
        return includesPlaybackTiming ? try addingPlaybackTiming(to: window, database: database) : window
    }

    /// Loads two independently duration-capped halves around `date`.
    public func timelineWindow(
        around date: Date,
        duration: TimeInterval,
        includesPlaybackTiming: Bool = false
    ) throws -> HistoricalTimelineSegmentWindow {
        try Task.checkCancellation()
        let database = try connect()
        let window = try LibraryDatabase.loadTimelineWindow(
            database: database,
            around: date,
            duration: duration
        )
        return includesPlaybackTiming ? try addingPlaybackTiming(to: window, database: database) : window
    }

    private func addingPlaybackTiming(to window: HistoricalTimelineSegmentWindow,
        database: OpaquePointer) throws -> HistoricalTimelineSegmentWindow {
        guard let start = window.segments.map(\.startDate).min(),
            let end = window.segments.map(\.endDate).max(), end > start else { return window }
        let interval = DateInterval(start: start, end: end)
        var dates = try playbackDates(database: database, interval: interval)
        if try isSharded(database) {
            let descriptors = try loadShardDescriptors(database).filter {
                $0.interval.end > interval.start && $0.interval.start < interval.end
            }
            // Missing metadata cannot supply a truthful frame-density scale.
            // Retain the existing axis until that metadata is hydrated.
            if descriptors.contains(where: { $0.state != .sealedLocal }) { return window }
            for descriptor in descriptors {
                let shard = try shardConnection(for: descriptor)
                dates += try playbackDates(database: shard.database, interval: interval)
            }
        }
        return .init(segments: window.segments, validSeekInterval: window.validSeekInterval,
            playbackFrameDates: Array(Set(dates)).sorted())
    }

    private func playbackDates(database: OpaquePointer, interval: DateInterval) throws -> [Date] {
        // Boundary neighbours keep spacing invariant when a moving window
        // cuts through the idle interval between two durable frames.
        let sql = """
            SELECT createdAt FROM frame WHERE createdAt >= ?1 AND createdAt <= ?2
            UNION SELECT MAX(createdAt) FROM frame WHERE createdAt < ?1
            UNION SELECT MIN(createdAt) FROM frame WHERE createdAt > ?2
            ORDER BY 1
            """
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else {
            throw LibraryDatabaseError.queryFailed(LibraryDatabase.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, LibraryDatabase.databaseString(interval.start), -1, transient)
        sqlite3_bind_text(statement, 2, LibraryDatabase.databaseString(interval.end), -1, transient)
        var dates: [Date] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return dates }
            guard result == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(LibraryDatabase.errorMessage(database))
            }
            if let value = LibraryDatabase.string(statement, column: 0) {
                dates.append(try LibraryDatabase.databaseDate(value))
            }
        }
    }

    /// Loads every segment intersecting an exact wall-clock interval. Daily
    /// Recap must not use the timeline's duration-capped pager: a day with many
    /// short segments could otherwise stop before reaching midnight. Segment
    /// dimension rows remain in the compact primary catalog after payloads are
    /// sealed or evicted, so this query also works for remote-only history
    /// without downloading media or transcript shards.
    public func timelineSegments(
      intersecting interval: DateInterval
    ) throws -> [TimelineSegment] {
      guard interval.duration > 0 else { return [] }
      let database = try connect()
      let sql = """
        SELECT id,startDate,endDate,bundleID,windowName,browserUrl,browserProfile,type
          FROM segment
         WHERE endDate > ? AND startDate < ?
         ORDER BY startDate ASC,id ASC
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(
        statement,
        1,
        LibraryDatabase.databaseString(interval.start),
        -1,
        transient
      )
      sqlite3_bind_text(
        statement,
        2,
        LibraryDatabase.databaseString(interval.end),
        -1,
        transient
      )
      var segments: [TimelineSegment] = []
      while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
          return segments
        case SQLITE_ROW:
          if let segment = try LibraryDatabase.decodeSegment(statement) {
            segments.append(segment)
          }
        default:
          throw LibraryDatabaseError.queryFailed(
            LibraryDatabase.errorMessage(database)
          )
        }
      }
    }

    /// Loads recorded meetings from the compact primary catalog for Daily
    /// Recap. Event metadata remains mutable in the primary database after the
    /// media/transcript payload moves to a sealed or remote-only shard.
    public func dailyRecapRecordedMeetings(
        intersecting interval: DateInterval
    ) throws -> [LibreReverseDailyRecapMeeting] {
        guard interval.duration > 0 else { return [] }
        let database = try connect()
        let sql = """
            SELECT s.id,s.startDate,s.endDate,
                   COALESCE(NULLIF(e.title,''),NULLIF(s.windowName,''),'Meeting'),s.browserUrl,
                   e.participants,e.detailsJSON,e.calendarID,e.calendarEventID,e.calendarSeriesID
              FROM segment s
              LEFT JOIN event e ON e.id=(SELECT MIN(id) FROM event WHERE segmentID=s.id)
             WHERE s.type=1 AND s.endDate > ? AND s.startDate < ?
             ORDER BY s.startDate DESC,s.id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(
            statement, 1, LibraryDatabase.databaseString(interval.start), -1, transient
        )
        sqlite3_bind_text(
            statement, 2, LibraryDatabase.databaseString(interval.end), -1, transient
        )
        var meetings: [LibreReverseDailyRecapMeeting] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return meetings
            case SQLITE_ROW:
                let metadata = Self.meetingTranscriptMetadata(
                    participantsJSON: LibraryDatabase.string(statement, column: 5),
                    detailsJSON: LibraryDatabase.string(statement, column: 6),
                    calendarID: LibraryDatabase.string(statement, column: 7),
                    calendarEventID: LibraryDatabase.string(statement, column: 8),
                    calendarSeriesID: LibraryDatabase.string(statement, column: 9)
                )
                meetings.append(
                    .init(
                        kind: .recorded,
                        segmentID: sqlite3_column_int64(statement, 0),
                        calendarEventID: metadata.calendarEventID,
                        title: LibraryDatabase.string(statement, column: 3) ?? "Meeting",
                        startDate: try LibraryDatabase.databaseDate(
                            LibraryDatabase.string(statement, column: 1) ?? ""
                        ),
                        endDate: try LibraryDatabase.databaseDate(
                            LibraryDatabase.string(statement, column: 2) ?? ""
                        ),
                        calendarTitle: metadata.calendarTitle,
                        participants: metadata.participants,
                        meetingURL: LibraryDatabase.string(statement, column: 4)
                            .flatMap(URL.init(string:))
                    )
                )
            default:
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
        }
    }

    public func meetingSummaryStatus(segmentID: Int64) throws -> String? {
        let database = try connect()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sm.status FROM summary sm JOIN event e ON e.id=sm.eventId WHERE e.segmentID=? LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryDatabaseError.queryFailed(LibraryDatabase.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, segmentID)
        return sqlite3_step(statement) == SQLITE_ROW ? LibraryDatabase.string(statement, column: 0) : nil
    }

    public func meetingSummary(segmentID: Int64) throws -> String? {
        let database = try connect()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            SELECT NULLIF(TRIM(sm.text),'')
              FROM event e
              JOIN summary sm ON sm.eventId=e.id
             WHERE e.segmentID=?
             ORDER BY e.id ASC
             LIMIT 1
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, segmentID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return LibraryDatabase.string(statement, column: 0)
    }

    /// Bulk star feed over the persistent database connection.
    /// Result order is the database’s native order.
    public func starredFrameDates() throws -> [Date] {
        let database = try connect()
      let sql =
        try isSharded(database)
        ? """
            SELECT createdAt FROM frame WHERE isStarred=1
            UNION ALL
            SELECT createdAt FROM shard_star
            """ : LibraryDatabase.starredFrameDatesSQL
        return try LibraryDatabase.query(
            database: database,
            sql: sql
        ) { statement in
            try LibraryDatabase.databaseDate(
                LibraryDatabase.string(statement, column: 0) ?? ""
            )
        }
    }

    /// Content-free corpus counts for signed read-only UI validation.
    /// No OCR text, transcript text, window title, URL, or timestamp leaves
    /// the database boundary.
    public func searchValidationInventory() throws
      -> HistoricalSearchValidationInventory
    {
        let database = try connect()
        var counts = try searchValidationCounts(database)
        var localShardCount = 0
        var unavailableShardCount = 0
        if try isSharded(database) {
            for descriptor in try loadShardDescriptors(database) {
                if descriptor.state == .sealedLocal {
                    localShardCount += 1
                    let shard = try shardConnection(for: descriptor)
                    let shardCounts = try searchValidationCounts(shard.database)
                    counts.documents += shardCounts.documents
                    counts.transcripts += shardCounts.transcripts
                    counts.starred += shardCounts.starred
                } else {
                    unavailableShardCount += 1
                }
            }
        }
        return HistoricalSearchValidationInventory(
            searchableDocumentCount: counts.documents,
            transcriptDocumentCount: counts.transcripts,
            starredFrameCount: counts.starred,
            locallyResidentShardCount: localShardCount,
            unavailableShardCount: unavailableShardCount
        )
    }

    private func searchValidationCounts(_ database: OpaquePointer) throws
      -> (documents: Int, transcripts: Int, starred: Int)
    {
        let sql = """
        SELECT COUNT(*),
               COALESCE(SUM(CASE WHEN s.type=\(SegmentType.audio.rawValue) THEN 1 ELSE 0 END),0),
               COUNT(DISTINCT CASE WHEN f.isStarred=1 THEN f.id END)
          FROM doc_segment ds
          JOIN segment s ON s.id=ds.segmentId
          LEFT JOIN frame f ON f.id=ds.frameId
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
        else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        return (
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1)),
            Int(sqlite3_column_int64(statement, 2))
        )
    }

    /// Fetches an amplified recency candidate page from each locally resident
    /// database, then merges by recorded time with document ID as a tie-break.
    /// Population and deduplication happen afterward.
    public func recencySearchCandidates(
        query: String,
        facets: SearchFacets = .init(),
        before cursor: SearchRecencyCursor? = nil,
        amplifiedLimit: Int = 450
    ) throws -> [HistoricalSearchCandidate] {
        let match = SearchQuery.matchExpression(for: query)
        guard amplifiedLimit > 0, match != nil || facets.isTranscript else { return [] }
        let database = try connect()
        var candidates = try recencySearchCandidates(
            database: database,
            match: match,
            facets: facets,
            before: cursor,
            limit: amplifiedLimit,
            requiredFrameIDs: nil
        )
        if try isSharded(database) {
            let catalogStarredFrameIDs = try shardStarredFrameIDs(database)
            for descriptor in try loadShardDescriptors(database)
            where descriptor.state == .sealedLocal && descriptor.frameCount > 0 {
                let shard = try shardConnection(for: descriptor)
                // Frame identifiers are preserved globally across shard
                // rollover, so the compact primary set is safe to apply to
                // each immutable database; non-owning IDs simply do not join.
                let requiredFrameIDs: Set<Int64>? = facets.isStarred
                    ? catalogStarredFrameIDs
                    : nil
                if facets.isStarred, requiredFrameIDs?.isEmpty == true { continue }
                var shardFacets = facets
                shardFacets.isStarred = false
                let shardCandidates = try recencySearchCandidates(
                    database: shard.database,
                    match: match,
                    facets: shardFacets,
                    before: cursor,
                    limit: amplifiedLimit,
                    requiredFrameIDs: requiredFrameIDs
                ).map {
                    candidate($0, isStarred: catalogStarredFrameIDs.contains($0.frameID ?? -1))
                }
                candidates.append(contentsOf: shardCandidates)
            }
        }
        // Order by recorded time: document identifiers are not chronological
        // across sealed shards and newly recorded primary rows. Identifier is
        // only the tie-break. Deduplicate defensively while a building generation
        // coexists with published intervals in the catalog.
        var seen: Set<Int64> = []
      return
        candidates
            .sorted {
                switch ($0.frameDate, $1.frameDate) {
          case (let lhs?, let rhs?) where lhs != rhs: return lhs > rhs
                case (nil, _?): return false
                case (_?, nil): return true
                default:
                    // Browsing uses negative segment identities; newest tied
                    // meetings still sort by descending segment ID.
                    return match == nil && facets.isTranscript
                        ? $0.segmentID > $1.segmentID : $0.docID > $1.docID
                }
            }
            .filter { seen.insert($0.docID).inserted }
            .prefix(amplifiedLimit)
            .map { $0 }
    }

    /// Bounded local-history excerpts for a time-only Ask request such as
    /// "What did I do yesterday?". This deliberately bypasses FTS because
    /// there is no lexical term, but preserves the same document/segment
    /// projection and composite-library merge used by search.
    public func askEvidenceCandidates(
        in interval: DateInterval,
        limit: Int = 120
    ) throws -> [HistoricalSearchCandidate] {
        guard limit > 0 else { return [] }
        let database = try connect()
        var values = try askEvidenceCandidates(
            database: database,
            interval: interval,
            limit: limit
        )
        if try isSharded(database) {
            for descriptor in try loadShardDescriptors(database)
            where descriptor.state == .sealedLocal && descriptor.frameCount > 0 {
                let shard = try shardConnection(for: descriptor)
                values.append(contentsOf: try askEvidenceCandidates(
                    database: shard.database,
                    interval: interval,
                    limit: limit
                ))
            }
        }
        var seen: Set<Int64> = []
        return values.sorted {
            ($0.frameDate ?? .distantPast) > ($1.frameDate ?? .distantPast)
        }.filter { seen.insert($0.docID).inserted }.prefix(limit).map { $0 }
    }

    /// Executes the FTS4 offset pass independently from ranking. The unbounded
    /// `docid, offsets(searchOffsets)` projection is joined to the amplified
    /// FTS5 candidate page by stable document ID during population.
    public func batchSearchOffsets(query: String) throws -> [Int64: String] {
        try batchSearchOffsets(query: query, docIDs: nil)
    }

    /// FTS4 `offsets()` for the matching documents.
    ///
    /// `docIDs` restricts the pass to the documents a page will actually
    /// render. Unrestricted, this computes offsets for every document matching
    /// the term across the primary and all sealed shards, which for a term as
    /// common as "the" is most of the corpus: 20 seconds of `offsets()` before
    /// a single result can be shown, against sub-second for a rare term. The
    /// restricted form returns exactly the same string for every document the
    /// caller asked about.
    public func batchSearchOffsets(
        query: String,
        docIDs: Set<Int64>?
    ) throws -> [Int64: String] {
        guard let match = SearchQuery.matchExpression(for: query) else {
            return [:]
        }
        if let docIDs, docIDs.isEmpty { return [:] }
        let database = try connect()
        var result = try batchSearchOffsets(
            database: database,
            match: match,
            docIDs: docIDs
        )
        if try isSharded(database) {
            // A document lives in exactly one database, so once every
            // requested id has an answer there is nothing left to look for.
            for descriptor in try loadShardDescriptors(database)
            where descriptor.state == .sealedLocal && descriptor.frameCount > 0 {
                if let docIDs, result.count == docIDs.count { break }
                let shard = try shardConnection(for: descriptor)
                for (docID, offsets) in try batchSearchOffsets(
                    database: shard.database,
                    match: match,
                    docIDs: docIDs
                ) where result[docID] == nil {
                    result[docID] = offsets
                }
            }
        }
        return result
    }

    /// Count app facets independently of active facets so choosing an app
    /// does not hide the remaining app choices.
    public func searchApplicationCounts(
        query: String
    ) throws -> [SearchApplicationCount] {
        guard let match = SearchQuery.matchExpression(for: query) else {
            return []
        }
        let database = try connect()
        var totals = try searchApplicationCounts(database: database, match: match)
        if try isSharded(database) {
            for descriptor in try loadShardDescriptors(database)
            where descriptor.state == .sealedLocal && descriptor.frameCount > 0 {
                try Task.checkCancellation()
                let shard = try shardConnection(for: descriptor)
                for (bundleID, count) in try searchApplicationCounts(
                    database: shard.database,
                    match: match
                ) {
                    totals[bundleID, default: 0] += count
                }
            }
        }
        return totals.map {
            SearchApplicationCount(bundleID: $0.key, count: $0.value)
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.bundleID < $1.bundleID
        }
    }

    private func searchApplicationCounts(
        database: OpaquePointer,
        match: String
    ) throws -> [String: Int] {
        try Task.checkCancellation()
        // SQLite checks this on the executing task while evaluating a large
        // MATCH/GROUP BY, so cancellation need not wait for its first row.
        sqlite3_progress_handler(database, 1_000, { _ in
            Task<Never, Never>.isCancelled ? 1 : 0
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        let sql = """
        SELECT s.bundleID,count(*)
          FROM segment s
          JOIN doc_segment ds ON s.id=ds.segmentId
          JOIN searchRanking sr ON sr.rowid=ds.docid AND searchRanking MATCH ?
          LEFT JOIN frame f ON f.id=ds.frameId
          LEFT JOIN video v ON v.id=f.videoId
         GROUP BY s.bundleID
         ORDER BY count(*) DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, match, -1, transient)
        var result: [String: Int] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            guard let bundleID = LibraryDatabase.string(statement, column: 0),
          !bundleID.isEmpty
        else { continue }
            result[bundleID] = Int(sqlite3_column_int64(statement, 1))
        }
    }

    private func batchSearchOffsets(
        database: OpaquePointer,
        match: String,
        docIDs: Set<Int64>? = nil
    ) throws -> [Int64: String] {
        var sql = """
        SELECT docid, offsets(searchOffsets)
          FROM searchOffsets
         WHERE searchOffsets MATCH ?
        """
        if let docIDs {
            // Interpolated rather than bound: SQLite has no list parameter,
            // and these are row ids this session just read out of its own
            // index, not caller text.
            sql += " AND docid IN (" + docIDs.map(String.init).joined(separator: ",") + ")"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, match, -1, transient)
        var result: [Int64: String] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            result[sqlite3_column_int64(statement, 0)] =
                LibraryDatabase.string(statement, column: 1) ?? ""
        }
    }

    private func recencySearchCandidates(
        database: OpaquePointer,
        match: String?,
        facets: SearchFacets,
        before cursor: SearchRecencyCursor?,
        limit: Int,
        requiredFrameIDs: Set<Int64>?
    ) throws -> [HistoricalSearchCandidate] {
        // Select the fields needed to populate results while preserving
        // candidate membership and ordering.
        var predicates: [String] = []
        if facets.isStarred {
            predicates.append(facets.isTranscript
                ? "EXISTS(SELECT 1 FROM frame starred WHERE starred.segmentId=s.id AND starred.isStarred = ?)"
                : "f.isStarred = ?")
        }
        if let requiredFrameIDs {
            guard !requiredFrameIDs.isEmpty else { return [] }
            let ids = requiredFrameIDs.sorted().map(String.init).joined(separator: ",")
            predicates.append(facets.isTranscript
                ? "EXISTS(SELECT 1 FROM frame starred WHERE starred.segmentId=s.id AND starred.id IN (\(ids)))"
                : "f.id IN (\(ids))")
        }
        let browsingMeetings = match == nil && facets.isTranscript
        if facets.isTranscript { predicates.append("s.type = 1") }
        let applicationBundleIDs = facets.isTranscript ? [] : facets.effectiveApplicationBundleIDs
        if !applicationBundleIDs.isEmpty {
            predicates.append(
          "s.bundleID IN ("
            + Array(
                    repeating: "?",
                    count: applicationBundleIDs.count
                ).joined(separator: ",") + ")"
            )
        }
        if let cursor {
            // Identifier order only matches recency inside one database, so a
            // cursor that has to carry across databases pages on the instant.
        predicates.append(
          cursor.instant == nil
            ? (browsingMeetings ? "-s.id > ?" : "sr.rowid < ?")
            : "(COALESCE(f.createdAt,s.startDate) < ? OR (COALESCE(f.createdAt,s.startDate) = ? AND \(browsingMeetings ? "-s.id >" : "sr.rowid <") ?))"
        )
        }
      let whereClause =
        predicates.isEmpty
            ? ""
            : " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        let documentJoin = browsingMeetings
            ? "LEFT JOIN doc_segment ds ON ds.docid=(SELECT MIN(d.docid) FROM doc_segment d WHERE d.segmentId=s.id AND d.frameId IS NULL) LEFT JOIN searchRanking sr ON sr.rowid=ds.docid"
            : "JOIN doc_segment ds ON s.id=ds.segmentId JOIN searchRanking sr ON sr.rowid=ds.docid AND searchRanking MATCH ?"
        // Browsing has no MATCH offsets: use one stable identity per meeting,
        // whether or not a real (possibly negative) document has been indexed.
        let documentID = browsingMeetings ? "-s.id" : "sr.rowid"
        // Negative identities sort ascending to preserve descending meeting ID
        // order. The cursor above advances with the corresponding greater-than.
        let documentOrder = browsingMeetings ? "ASC" : "DESC"
        let sql = """
        SELECT f.id,COALESCE(f.createdAt,s.startDate),f.isStarred,s.id,s.bundleID,s.windowName,
               s.browserUrl,s.type,sr.text,sr.otherText,\(documentID)
          FROM segment s
          \(documentJoin)
          LEFT JOIN frame f ON f.id=ds.frameId
          LEFT JOIN video v ON v.id=f.videoId
        \(whereClause)
         ORDER BY COALESCE(f.createdAt,s.startDate) DESC, \(documentID) \(documentOrder)
         LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var binding: Int32 = 1
        if let match {
            sqlite3_bind_text(statement, binding, match, -1, transient)
            binding += 1
        }
        if facets.isStarred {
            sqlite3_bind_int(statement, binding, 1)
            binding += 1
        }
        for bundleID in applicationBundleIDs {
            sqlite3_bind_text(statement, binding, bundleID, -1, transient)
            binding += 1
        }
        if let cursor {
            if let instant = cursor.instant {
                sqlite3_bind_text(
                    statement,
                    binding,
                    LibraryDatabase.databaseFormatter.string(from: instant),
                    -1,
                    transient
                )
                binding += 1
                sqlite3_bind_text(statement, binding,
                    LibraryDatabase.databaseFormatter.string(from: instant), -1, transient)
                binding += 1
                sqlite3_bind_int64(statement, binding, cursor.documentID)
            } else {
                sqlite3_bind_int64(statement, binding, cursor.documentID)
            }
            binding += 1
        }
        sqlite3_bind_int(statement, binding, Int32(clamping: limit))
        var result: [HistoricalSearchCandidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            let frameDate = try LibraryDatabase.optionalDatabaseDate(
                LibraryDatabase.string(statement, column: 1)
            )
        result.append(
          HistoricalSearchCandidate(
                docID: sqlite3_column_int64(statement, 10),
                frameID: LibraryDatabase.optionalInt64(statement, column: 0),
                segmentID: sqlite3_column_int64(statement, 3),
                frameDate: frameDate,
                isStarred: sqlite3_column_int(statement, 2) != 0,
                bundleID: LibraryDatabase.string(statement, column: 4),
                windowName: LibraryDatabase.string(statement, column: 5),
                browserURL: LibraryDatabase.string(statement, column: 6),
                segmentType: SegmentType(
                    rawValue: Int(sqlite3_column_int64(statement, 7))
                ) ?? .capturedScreen,
                text: LibraryDatabase.string(statement, column: 8) ?? "",
                otherText: LibraryDatabase.string(statement, column: 9) ?? ""
            ))
        }
    }

    private func askEvidenceCandidates(
        database: OpaquePointer,
        interval: DateInterval,
        limit: Int
    ) throws -> [HistoricalSearchCandidate] {
        let sql = """
        SELECT f.id,COALESCE(f.createdAt,s.startDate),f.isStarred,s.id,s.bundleID,s.windowName,
               s.browserUrl,s.type,sr.text,sr.otherText,sr.rowid
          FROM segment s
          JOIN doc_segment ds ON s.id=ds.segmentId
          JOIN searchRanking sr ON sr.rowid=ds.docid
          LEFT JOIN frame f ON f.id=ds.frameId
         WHERE COALESCE(f.createdAt,s.startDate) >= ?
           AND COALESCE(f.createdAt,s.startDate) < ?
         ORDER BY COALESCE(f.createdAt,s.startDate) DESC,sr.rowid DESC
         LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(
            statement, 1,
            LibraryDatabase.databaseFormatter.string(from: interval.start),
            -1, transient
        )
        sqlite3_bind_text(
            statement, 2,
            LibraryDatabase.databaseFormatter.string(from: interval.end),
            -1, transient
        )
        sqlite3_bind_int(statement, 3, Int32(clamping: limit))
        var result: [HistoricalSearchCandidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            result.append(
                HistoricalSearchCandidate(
                    docID: sqlite3_column_int64(statement, 10),
                    frameID: LibraryDatabase.optionalInt64(statement, column: 0),
                    segmentID: sqlite3_column_int64(statement, 3),
                    frameDate: try LibraryDatabase.optionalDatabaseDate(
                        LibraryDatabase.string(statement, column: 1)
                    ),
                    isStarred: sqlite3_column_int(statement, 2) != 0,
                    bundleID: LibraryDatabase.string(statement, column: 4),
                    windowName: LibraryDatabase.string(statement, column: 5),
                    browserURL: LibraryDatabase.string(statement, column: 6),
                    segmentType: SegmentType(
                        rawValue: Int(sqlite3_column_int64(statement, 7))
                    ) ?? .capturedScreen,
                    text: LibraryDatabase.string(statement, column: 8) ?? "",
                    otherText: LibraryDatabase.string(statement, column: 9) ?? ""
                )
            )
        }
    }

    private func shardStarredFrameIDs(_ database: OpaquePointer) throws -> Set<Int64> {
        Set(
            try LibraryDatabase.query(
                database: database,
                sql: "SELECT frameId FROM shard_star"
            ) { statement in
                sqlite3_column_int64(statement, 0)
            }
        )
    }

    private func candidate(
        _ value: HistoricalSearchCandidate,
        isStarred: Bool
    ) -> HistoricalSearchCandidate {
        HistoricalSearchCandidate(
            docID: value.docID,
            frameID: value.frameID,
            segmentID: value.segmentID,
            frameDate: value.frameDate,
            isStarred: isStarred,
            bundleID: value.bundleID,
            windowName: value.windowName,
            browserURL: value.browserURL,
            segmentType: value.segmentType,
            text: value.text,
            otherText: value.otherText
        )
    }

    /// Populates audio/transcript documents without inventing a frame or OCR
    /// node. The first matching UTF-16 text offset is joined to the nearest
    /// persisted transcript word, whose whole-second offset reconstructs the seek
    /// instant from the owning segment start.
    public func recencyTranscriptSearchPage(
      query: String,
      facets: SearchFacets = .init(isTranscript: true),
      before cursor: SearchRecencyCursor? = nil,
      pageSize: Int = 30,
      amplifiedLimit: Int = 450,
      previousResults: [TranscriptSearchResult] = []
    ) throws -> TranscriptSearchPage {
      guard pageSize > 0, amplifiedLimit > 0 else {
        return .init(results: [], nextCursor: nil, hasMore: false, offsetsByDocument: [:])
      }
      let candidates = try recencySearchCandidates(
        query: query,
        facets: .init(applicationBundleIDs: facets.applicationBundleIDs,
            isStarred: facets.isStarred, isTranscript: true),
        before: cursor,
        amplifiedLimit: amplifiedLimit
      )
      let offsets = try batchSearchOffsets(
        query: query,
        docIDs: Set(candidates.map(\.docID))
      )
      var populated: [PopulatedSearchResult] = []
      for candidate in candidates where candidate.segmentType == .audio {
        guard let segmentStart = candidate.frameDate else { continue }
        let offsetString = offsets[candidate.docID] ?? ""
        let firstTextOffset = SearchOffsetParser.orderedForFirstMatch(
          SearchOffsetParser.parse(
            offsetString,
            primaryText: candidate.text,
            otherText: candidate.otherText
          )
        ).first(where: { $0.column == .primaryText })?.lowerBound
        let match = try transcriptMatch(
          segmentID: candidate.segmentID,
          segmentStart: segmentStart,
          fullTextOffset: firstTextOffset
        )
        let details = PopulatedSearchResult.TranscriptDetails(
          id: match?.wordID ?? candidate.segmentID,
          transcript: candidate.text,
          matchInstant: segmentStart.addingTimeInterval(
            TimeInterval(match?.timeOffset ?? 0)
          )
        )
        populated.append(
          .init(
            candidate: candidate,
            representativeInstant: details.matchInstant,
            resolvedTitle: candidate.windowName ?? "Meeting",
            segmentType: .audio,
            matchRectangle: nil,
            transcriptDetails: details
          ))
      }

      let previousPopulated = previousResults.map(\.result)
      let browsing = SearchQuery.matchExpression(for: query) == nil
      let reduced = browsing ? populated : SearchResultDeduplicator.reduce(
        Array(previousPopulated.suffix(SearchResultDeduplicator.defaultLookback))
          + populated
      )
      let previousIDs = Set(previousResults.map { $0.result.candidate.docID })
      let eligible = reduced.compactMap { result -> TranscriptSearchResult? in
        guard !previousIDs.contains(result.candidate.docID) else { return nil }
        return .init(result: result)
      }
      let page = Array(eligible.prefix(pageSize))
      let hasMore = eligible.count > page.count || candidates.count == amplifiedLimit
      let lastCandidate = page.last?.result.candidate ?? candidates.last
      return .init(
        results: Array(page),
        nextCursor: hasMore
          ? lastCandidate.map {
            .init(documentID: $0.docID, instant: $0.frameDate)
          } : nil,
        hasMore: hasMore,
        offsetsByDocument: offsets
      )
    }

    private func transcriptMatch(
      segmentID: Int64,
      segmentStart: Date,
      fullTextOffset: Int?
    ) throws -> (wordID: Int64, timeOffset: Int)? {
      guard let fullTextOffset else { return nil }
      let database = try connect()
      if let value = try transcriptMatch(
        database: database,
        segmentID: segmentID,
        fullTextOffset: fullTextOffset
      ) {
        return value
      }
      if try isSharded(database),
        let descriptor = try loadShardDescriptors(database).first(where: {
          $0.state == .sealedLocal && $0.interval.contains(segmentStart)
        })
      {
        return try transcriptMatch(
          database: try shardConnection(for: descriptor).database,
          segmentID: segmentID,
          fullTextOffset: fullTextOffset
        )
      }
      return nil
    }

    private func transcriptMatch(
      database: OpaquePointer,
      segmentID: Int64,
      fullTextOffset: Int
    ) throws -> (wordID: Int64, timeOffset: Int)? {
      var statement: OpaquePointer?
      let sql = """
        SELECT w.id,w.timeOffset
          FROM transcript_word w
          JOIN segment s ON s.id=w.segmentId AND s.type=1
         WHERE w.segmentId=? AND w.fullTextOffset IS NOT NULL
           AND w.fullTextOffset<=?
         ORDER BY w.fullTextOffset DESC,w.id DESC
         LIMIT 1
        """
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, segmentID)
      sqlite3_bind_int64(statement, 2, Int64(fullTextOffset))
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return nil }
      guard status == SQLITE_ROW else {
        throw LibraryDatabaseError.queryFailed(
          LibraryDatabase.errorMessage(database)
        )
      }
      return (
        wordID: sqlite3_column_int64(statement, 0),
        timeOffset: Int(sqlite3_column_int64(statement, 1))
      )
    }

    /// Populates frame-backed recency candidates using the independent FTS4
    /// offset pass, first-node assembly, and bounded result reduction.
    /// Audio and transcript documents use their own population path.
    public func recencyOCRSearchResults(
        query: String,
        facets: SearchFacets = .init(),
        before cursor: SearchRecencyCursor? = nil,
        applicationNames: [String: String] = [:],
        amplifiedLimit: Int = 450
    ) throws -> [OCRSearchResult] {
        try recencyOCRSearchPage(
            query: query,
            facets: facets,
            before: cursor,
            applicationNames: applicationNames,
            amplifiedLimit: amplifiedLimit
        ).results
    }

    public func recencyOCRSearchPage(
        query: String,
        facets: SearchFacets = .init(),
        before cursor: SearchRecencyCursor? = nil,
        applicationNames: [String: String] = [:],
        pageSize: Int = 30,
        amplifiedLimit: Int = 450,
        previousResults: [OCRSearchResult] = [],
        preloadedOffsetsByDocument: [Int64: String]? = nil
    ) throws -> OCRSearchPage {
        guard pageSize > 0, amplifiedLimit > 0 else {
            return OCRSearchPage(results: [], nextCursor: nil, hasMore: false)
        }
        let candidates = try recencySearchCandidates(
            query: query,
            facets: facets,
            before: cursor,
            amplifiedLimit: amplifiedLimit
        )
        // Offsets are resolved for the candidates this page actually has,
        // never for the whole match set.
      let offsetsByDocument =
        try preloadedOffsetsByDocument
            ?? batchSearchOffsets(query: query, docIDs: Set(candidates.map(\.docID)))
        var nodesByDocument: [Int64: OCRNode] = [:]
        var populated: [PopulatedSearchResult] = []
        populated.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard candidate.segmentType != .audio,
                  let frameID = candidate.frameID,
                  let instant = candidate.frameDate,
                  let offsetString = offsetsByDocument[candidate.docID],
                  let firstNode = try firstMatchingOCRNode(
                    frameID: frameID,
                    offsetString: offsetString,
                    primaryText: candidate.text,
                    otherText: candidate.otherText,
                    instant: instant
          )
        else {
                continue
            }
        let title =
          candidate.windowName
                ?? candidate.bundleID.flatMap { applicationNames[$0] }
                ?? "Untitled"
            nodesByDocument[candidate.docID] = firstNode
        populated.append(
          PopulatedSearchResult(
                candidate: candidate,
                representativeInstant: instant,
                resolvedTitle: title,
                segmentType: candidate.segmentType,
                matchRectangle: .init(width: firstNode.width, height: firstNode.height)
            ))
        }

        let previousPopulated = previousResults.map(\.result)
        let reduced = SearchResultDeduplicator.reduce(
            Array(previousPopulated.suffix(SearchResultDeduplicator.defaultLookback))
                + populated
        )
        let previousDocumentIDs = Set(previousResults.map { $0.result.candidate.docID })
        let pageResults = reduced.compactMap { result -> OCRSearchResult? in
            guard !previousDocumentIDs.contains(result.candidate.docID),
          let node = nodesByDocument[result.candidate.docID]
        else { return nil }
            return OCRSearchResult(result: result, firstNode: node)
        }
        let visibleResults = Array(pageResults.prefix(pageSize))
        let hasMore = pageResults.count > pageSize || candidates.count == amplifiedLimit
        // Do not advance past eligible rows that were never displayed. If all
        // examined rows were filtered out, advance the raw cursor to make progress.
        let lastExamined = visibleResults.last?.result.candidate ?? candidates.last
        return OCRSearchPage(
            results: visibleResults,
        nextCursor: hasMore
          ? lastExamined.map {
                SearchRecencyCursor(documentID: $0.docID, instant: $0.frameDate)
            } : nil,
            hasMore: hasMore,
            offsetsByDocument: offsetsByDocument
        )
    }

    /// Resolves the first OCR node overlapping a query offset. Node offsets
    /// use global document coordinates, while FTS offsets are column-relative.
    /// For `otherText`, subtract the primary column’s UTF-16 length in SQL
    /// and accept nonzero window indexes; primary hits require window zero.
    public func firstMatchingOCRNode(
        frameID: Int64,
        primaryTextUTF16Length: Int,
        offset: SearchQueryOffset,
        instant: Date? = nil
    ) throws -> OCRNode? {
        let database = try connect()
        if let node = try firstMatchingOCRNode(
            database: database,
            frameID: frameID,
            primaryTextUTF16Length: primaryTextUTF16Length,
            offset: offset
      ) {
        return node
      }

        if try isSharded(database) {
            for descriptor in try searchableShards(database, preferring: instant) {
                let shard = try shardConnection(for: descriptor)
                if let node = try firstMatchingOCRNode(
                    database: shard.database,
                    frameID: frameID,
                    primaryTextUTF16Length: primaryTextUTF16Length,
                    offset: offset
          ) {
            return node
          }
            }
        }
        return nil
    }

    /// Loads persisted OCR nodes for a frame in `nodeOrder`. Frame IDs are
    /// stable across immutable shards. Probe the active primary first, then
    /// locally resident shards with frame payloads.
    public func ocrNodes(frameID: Int64, instant: Date? = nil) throws -> [OCRNode] {
        let database = try connect()
        let primary = try ocrNodes(database: database, frameID: frameID)
        if !primary.isEmpty { return primary }

        if try isSharded(database) {
            for descriptor in try searchableShards(database, preferring: instant) {
                let shard = try shardConnection(for: descriptor)
                let nodes = try ocrNodes(database: shard.database, frameID: frameID)
                if !nodes.isEmpty { return nodes }
            }
        }
        return []
    }

    private func ocrNodes(
        database: OpaquePointer,
        frameID: Int64
    ) throws -> [OCRNode] {
        let sql = #"SELECT * FROM "node" WHERE ("frameId" = ?) ORDER BY "nodeOrder""#
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, frameID)
        var nodes: [OCRNode] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                nodes.append(Self.decodeOCRNode(statement))
            case SQLITE_DONE:
                return nodes
            default:
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
        }
    }

    /// Resolves the first match from raw FTS4 offsets through UTF-16
    /// correction, ordering, and overlap SQL.
    public func firstMatchingOCRNode(
        frameID: Int64,
        offsetString: String,
        primaryText: String,
        otherText: String,
        instant: Date? = nil
    ) throws -> OCRNode? {
        let offsets = SearchOffsetParser.orderedForFirstMatch(
            SearchOffsetParser.parse(
                offsetString,
                primaryText: primaryText,
                otherText: otherText
            )
        )
        guard let first = offsets.first else { return nil }
        return try firstMatchingOCRNode(
            frameID: frameID,
            primaryTextUTF16Length: primaryText.utf16.count,
            offset: first,
            instant: instant
        )
    }

    private func firstMatchingOCRNode(
        database: OpaquePointer,
        frameID: Int64,
        primaryTextUTF16Length: Int,
        offset: SearchQueryOffset
    ) throws -> OCRNode? {
        let windowPredicate: String
        let shift: Int
        switch offset.column {
        case .primaryText:
            windowPredicate = "="
            shift = 0
        case .otherText:
            windowPredicate = "!="
            shift = primaryTextUTF16Length
        }
        let sql = """
        SELECT * FROM "node"
         WHERE ((("frameId" = ?)
           AND ((("textOffset" - ?) <= ?)
           AND ((("textOffset" + "textLength") - ?) >= ?)))
           AND ("windowIndex" \(windowPredicate) ?))
         ORDER BY "nodeOrder" LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, frameID)
        sqlite3_bind_int64(statement, 2, Int64(shift))
        sqlite3_bind_int64(statement, 3, Int64(offset.upperBound))
        sqlite3_bind_int64(statement, 4, Int64(shift))
        sqlite3_bind_int64(statement, 5, Int64(offset.lowerBound))
        sqlite3_bind_int64(statement, 6, 0)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        return Self.decodeOCRNode(statement)
    }

    private static func decodeOCRNode(_ statement: OpaquePointer) -> OCRNode {
        OCRNode(
            nodeOrder: Int(sqlite3_column_int64(statement, 2)),
            textOffset: Int(sqlite3_column_int64(statement, 3)),
            textLength: Int(sqlite3_column_int64(statement, 4)),
            leftX: sqlite3_column_double(statement, 5),
            topY: sqlite3_column_double(statement, 6),
            width: sqlite3_column_double(statement, 7),
            height: sqlite3_column_double(statement, 8),
            windowIndex: Int(sqlite3_column_int64(statement, 9))
        )
    }

    /// Returns the first recorded segment start in each occupied stored hour
    /// intersecting `interval`. Retained primary segment metadata covers local,
    /// evicted, and remote-only history without loading shard payloads.
    public func availableFrameHours(in interval: DateInterval) throws -> [Date] {
        guard interval.duration >= 0 else { return [] }
        let database = try connect()
        return try hourSamples(
            database: database,
            table: "segment",
            timestampColumn: "startDate",
            interval: interval
        )
    }

    /// Returns the first recorded segment within each requested period.
    /// Callers construct periods using their local calendar to preserve
    /// midnight and hour boundaries across daylight-saving transitions.
    public func firstRecordingInPeriods(_ periods: [DateInterval]) throws -> [Date] {
        guard !periods.isEmpty else { return [] }
        let database = try connect()
        let values = Array(repeating: "(?, ?)", count: periods.count)
            .joined(separator: ", ")
        let sql = """
            WITH periods(current, next) AS (VALUES \(values))
            SELECT MIN(segment.startDate)
              FROM periods
              JOIN segment ON segment.startDate >= periods.current
                          AND segment.startDate < periods.next
             GROUP BY periods.current
             ORDER BY periods.current
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, period) in periods.enumerated() {
            sqlite3_bind_text(
                statement, Int32(offset * 2 + 1),
                LibraryDatabase.databaseString(period.start), -1, transient
            )
            sqlite3_bind_text(
                statement, Int32(offset * 2 + 2),
                LibraryDatabase.databaseString(period.end), -1, transient
            )
        }
        var samples: [Date] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return samples }
            guard status == SQLITE_ROW,
          let value = LibraryDatabase.string(statement, column: 0)
        else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            samples.append(try LibraryDatabase.databaseDate(value))
        }
    }

    private func hourSamples(
        database: OpaquePointer,
        table: String,
        timestampColumn: String,
        interval: DateInterval
    ) throws -> [Date] {
        // Both identifiers are private constants selected by this type, never
        // caller input. Grouping by the stored UTC hour uses the existing
        // createdAt index for the range and bounds the result to 24 rows/day.
        let sql = """
            SELECT MIN(\(timestampColumn)) FROM \(table)
             WHERE \(timestampColumn)>=? AND \(timestampColumn)<?
             GROUP BY substr(\(timestampColumn),1,13)
             ORDER BY MIN(\(timestampColumn))
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
        let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(
            statement, 1,
            LibraryDatabase.databaseString(interval.start), -1, transient
        )
        sqlite3_bind_text(
            statement, 2,
            LibraryDatabase.databaseString(interval.end), -1, transient
        )
        var dates: [Date] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return dates }
            guard status == SQLITE_ROW,
          let value = LibraryDatabase.string(statement, column: 0)
        else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            dates.append(try LibraryDatabase.databaseDate(value))
        }
    }

    private func isSharded(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            database,
            "SELECT routingState FROM shard_metadata WHERE id=1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(LibraryDatabase.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LibraryDatabaseError.queryFailed("Library shard metadata is missing or unreadable")
        }
        return LibraryDatabase.string(statement, column: 0) == "sharded"
    }

    private func hasTable(_ name: String, database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func loadShardDescriptors(
        _ database: OpaquePointer
    ) throws -> [ShardDescriptor] {
        if let shardDescriptors { return shardDescriptors }
        var epochStatement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            database,
            "SELECT epochStart FROM shard_metadata WHERE id=1",
            -1,
            &epochStatement,
            nil
        ) == SQLITE_OK, let epochStatement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(epochStatement) }
        guard sqlite3_step(epochStatement) == SQLITE_ROW,
              let epochText = LibraryDatabase.string(epochStatement, column: 0),
        let epoch = Self.shardDate(epochText)
      else {
            throw LibraryDatabaseError.invalidDate(
                LibraryDatabase.string(epochStatement, column: 0) ?? ""
            )
        }

        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          database,
          """
            SELECT s.id,s.ordinal,s.relativePath,s.state,s.frameCount
              FROM library_shard s
             WHERE s.generation=(
               SELECT MAX(newer.generation) FROM library_shard newer
                WHERE newer.ordinal=s.ordinal
             )
             ORDER BY s.ordinal
          """, -1, &statement, nil) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        var result: [ShardDescriptor] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let rawState = LibraryDatabase.string(statement, column: 3),
          let state = LibreReverseShardState(rawValue: rawState)
        else {
                throw LibraryDatabaseError.queryFailed(
                    LibraryDatabase.errorMessage(database)
                )
            }
            let ordinal = sqlite3_column_int64(statement, 1)
        result.append(
          ShardDescriptor(
                id: sqlite3_column_int64(statement, 0),
                ordinal: ordinal,
                interval: .init(ordinal: ordinal, epochStart: epoch),
                relativePath: LibraryDatabase.string(statement, column: 2),
                state: state,
                frameCount: sqlite3_column_int64(statement, 4)
            ))
        }
        shardDescriptors = result
        return result
    }

    private func relevantDescriptors(
        for date: Date,
        descriptors: [ShardDescriptor]
    ) -> [ShardDescriptor] {
        let containing = descriptors.first { $0.interval.contains(date) }
        let before: ShardDescriptor?
        let after: ShardDescriptor?
        if let containing {
            before = descriptors.last {
                $0.ordinal < containing.ordinal && $0.frameCount > 0
            }
            after = descriptors.first {
                $0.ordinal > containing.ordinal && $0.frameCount > 0
            }
        } else {
            before = descriptors.last {
                $0.interval.end <= date && $0.frameCount > 0
            }
            after = descriptors.first {
                $0.interval.start > date && $0.frameCount > 0
            }
        }
        var seen: Set<Int64> = []
        return [containing, before, after].compactMap { descriptor in
            guard let descriptor, seen.insert(descriptor.id).inserted else { return nil }
            return descriptor
        }
    }

    /// Sealed, locally resident shards with payloads, ordered so the shard
    /// whose interval contains `instant` is probed first.
    ///
    /// Frame IDs are unique across shards, so a sweep is correct but pays for
    /// every shard that cannot possibly hold the frame. The candidate's own
    /// timestamp identifies the one shard that can, which turns the common
    /// case from ten encrypted database probes into one. The remaining shards
    /// are still visited afterwards, so an interval that disagrees with where
    /// a frame actually landed costs time but never a missed result.
    private func searchableShards(
        _ database: OpaquePointer,
        preferring instant: Date?
    ) throws -> [ShardDescriptor] {
        let sealed = try loadShardDescriptors(database)
            .filter { $0.state == .sealedLocal && $0.frameCount > 0 }
        guard let instant,
              let index = sealed.firstIndex(where: { $0.interval.contains(instant) })
        else { return sealed }
        var ordered = sealed
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    private func shardConnection(for descriptor: ShardDescriptor) throws -> ShardConnection {
        if let existing = shardConnections[descriptor.id] {
            touchShard(descriptor.id)
            return existing
        }
        guard let relativePath = descriptor.relativePath else {
            throw LibraryDatabaseError.shardUnavailable(
                ordinal: descriptor.ordinal,
                state: descriptor.state.rawValue
            )
        }
        let libraryRoot = configuration.databaseURL.deletingLastPathComponent()
            .standardizedFileURL
        let url = libraryRoot.appendingPathComponent(relativePath).standardizedFileURL
      let rootPrefix =
        libraryRoot.path.hasSuffix("/")
            ? libraryRoot.path : libraryRoot.path + "/"
        guard url.path.hasPrefix(rootPrefix) else {
            throw LibraryDatabaseError.queryFailed("unsafe shard path")
        }
        let shardConfiguration = LibraryDatabaseConfiguration(
            databaseURL: url,
            keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot,
            frameImagesRoot: configuration.frameImagesRoot
        )
      let opened = ShardConnection(
        database: try LibraryDatabase.openKeyedDatabase(
            configuration: shardConfiguration
        ))
        shardConnections[descriptor.id] = opened
        touchShard(descriptor.id)
        while shardLRU.count > shardConnectionCapacity, let evicted = shardLRU.first {
            shardLRU.removeFirst()
            shardConnections.removeValue(forKey: evicted)?.close()
        }
        return opened
    }

    private func touchShard(_ id: Int64) {
        shardLRU.removeAll { $0 == id }
        shardLRU.append(id)
    }

    private func preparedBeforeStatement(_ shard: ShardConnection) throws -> OpaquePointer {
        if let before = shard.before { return before }
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            shard.database,
            LibraryDatabase.momentAtOrBeforeSQL,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(shard.database)
            )
        }
        shard.before = statement
        return statement
    }

    private func preparedAfterStatement(_ shard: ShardConnection) throws -> OpaquePointer {
        if let after = shard.after { return after }
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            shard.database,
            LibraryDatabase.momentAfterSQL,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(shard.database)
            )
        }
        shard.after = statement
        return statement
    }

    private static func shardDate(_ value: String) -> Date? {
        shardISO8601Formatter.date(from: value)
            ?? LibraryDatabase.databaseFormatter.date(from: value)
    }

    private static let shardISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func preparedMomentAtOrBeforeStatement(
        _ database: OpaquePointer
    ) throws -> OpaquePointer {
        if let momentAtOrBeforeStatement { return momentAtOrBeforeStatement }
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            database, LibraryDatabase.momentAtOrBeforeSQL, -1, &statement, nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        momentAtOrBeforeStatement = statement
        return statement
    }

    private func preparedMomentAfterStatement(
        _ database: OpaquePointer
    ) throws -> OpaquePointer {
        if let momentAfterStatement { return momentAfterStatement }
        var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
            database, LibraryDatabase.momentAfterSQL, -1, &statement, nil
        ) == SQLITE_OK, let statement
      else {
            throw LibraryDatabaseError.queryFailed(
                LibraryDatabase.errorMessage(database)
            )
        }
        momentAfterStatement = statement
        return statement
    }
}
#endif
