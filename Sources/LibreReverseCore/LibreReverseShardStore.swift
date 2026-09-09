#if os(macOS)
import CSQLCipher
import Foundation

public enum LibreReverseShardState: String, CaseIterable, Sendable {
    case building
    case sealedLocal = "sealed_local"
    case remoteOnly = "remote_only"
    case rehydrating
    case failed
    case corrupt
}

public struct LibreReverseShardInterval: Equatable, Sendable {
    public static let duration: TimeInterval = 30 * 86_400

    public let ordinal: Int64
    public let start: Date
    public let end: Date

    public init(ordinal: Int64, epochStart: Date) {
        self.ordinal = ordinal
        start = epochStart.addingTimeInterval(Double(ordinal) * Self.duration)
        end = start.addingTimeInterval(Self.duration)
    }

    public static func ordinal(containing date: Date, epochStart: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince(epochStart) / duration))
    }

    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }

    public var fileName: String {
        Self.fileDateFormatter.string(from: start)
            + "-" + Self.fileDateFormatter.string(from: end)
            + ".sqlite3"
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

public struct LibreReverseShardRecord: Equatable, Sendable {
    public let id: Int64
    public let interval: LibreReverseShardInterval
    public let generation: Int
    public let relativePath: String?
    public let state: LibreReverseShardState
    public let byteCount: Int64?
    public let sha256: String?
    public let frameCount: Int64
    public let nodeCount: Int64
    public let documentCount: Int64
    public let minFrameID: Int64?
    public let maxFrameID: Int64?
    public let lastError: String?
}

public enum LibreReverseShardStoreError: Error, Equatable {
    case unableToOpenDatabase(String)
    case unableToApplyKey(Int32)
    case sqlite(String)
    case invalidEpoch(String)
    case invalidState(String)
    case invalidRelativePath(String)
    case overlappingInterval
    case missingShard(Int64)
    case invalidTransition(from: LibreReverseShardState, to: LibreReverseShardState)
}

/// Catalog and lifecycle boundary for immutable 30-day SQLCipher shards.
///
/// The current monolith remains authoritative until shard construction finishes.
/// Creating the catalog does not change query routing or move user data.
public enum LibreReverseShardStore {
    public static func initialize(_ configuration: LibreReverseLibraryConfiguration) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, schemaSQL)
            var statement: OpaquePointer?
            try prepare(database, "SELECT COUNT(*) FROM shard_metadata", &statement)
            let countStatement = try unwrap(statement, database)
            defer { sqlite3_finalize(countStatement) }
            guard sqlite3_step(countStatement) == SQLITE_ROW else {
                throw sqliteError(database)
            }
            if sqlite3_column_int64(countStatement, 0) == 0 {
                let minimum = try optionalText(
                    database,
                    "SELECT MIN(createdAt) FROM frame"
                )
                let epoch = try utcMidnight(
                    minimum.flatMap(databaseDate) ?? Date()
                )
                try insertMetadata(epochStart: epoch, database: database)
            }
            try execute(database, """
                INSERT INTO video_frame_bounds(videoId,minCreatedAt,maxCreatedAt,frameCount)
                SELECT videoId,MIN(createdAt),MAX(createdAt),COUNT(*) FROM frame
                 WHERE videoId IS NOT NULL GROUP BY videoId
                ON CONFLICT(videoId) DO UPDATE SET
                  minCreatedAt=excluded.minCreatedAt,
                  maxCreatedAt=excluded.maxCreatedAt,
                  frameCount=excluded.frameCount;
                """)
        }
    }

    public static func epochStart(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Date {
        try withDatabase(configuration, create: false, session: session) { database in
            guard let text = try optionalText(
                database,
                "SELECT epochStart FROM shard_metadata WHERE id=1"
            ), let date = databaseDate(text) else {
                throw LibreReverseShardStoreError.invalidEpoch("missing catalog epoch")
            }
            return date
        }
    }

    public static func interval(
        containing date: Date,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseShardInterval {
        let epoch = try epochStart(configuration: configuration)
        return LibreReverseShardInterval(
            ordinal: LibreReverseShardInterval.ordinal(containing: date, epochStart: epoch),
            epochStart: epoch
        )
    }

    public static func activeOrdinal(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64? {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT activeOrdinal FROM shard_metadata WHERE id=1",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            guard sqlite3_step(value) == SQLITE_ROW,
                  sqlite3_column_type(value, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(value, 0)
        }
    }

    public static func records(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseShardRecord] {
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        let epoch = try epochStart(configuration: configuration, session: session)
        return try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(database, """
                SELECT id,ordinal,generation,relativePath,state,byteCount,sha256,
                       frameCount,nodeCount,documentCount,minFrameId,maxFrameId,lastError
                  FROM library_shard ORDER BY ordinal,generation
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            var result: [LibreReverseShardRecord] = []
            while sqlite3_step(value) == SQLITE_ROW {
                guard let rawState = string(value, column: 4),
                      let state = LibreReverseShardState(rawValue: rawState) else {
                    throw LibreReverseShardStoreError.invalidState(
                        string(value, column: 4) ?? "<null>"
                    )
                }
                let ordinal = sqlite3_column_int64(value, 1)
                result.append(LibreReverseShardRecord(
                    id: sqlite3_column_int64(value, 0),
                    interval: .init(ordinal: ordinal, epochStart: epoch),
                    generation: Int(sqlite3_column_int64(value, 2)),
                    relativePath: string(value, column: 3),
                    state: state,
                    byteCount: optionalInt64(value, column: 5),
                    sha256: string(value, column: 6),
                    frameCount: sqlite3_column_int64(value, 7),
                    nodeCount: sqlite3_column_int64(value, 8),
                    documentCount: sqlite3_column_int64(value, 9),
                    minFrameID: optionalInt64(value, column: 10),
                    maxFrameID: optionalInt64(value, column: 11),
                    lastError: string(value, column: 12)
                ))
            }
            return result
        }
    }

    /// Materializes the compact jump-to-date availability index before a
    /// verified local shard may be removed. Repeating this operation is safe:
    /// the shard is immutable and the primary replacement is transactional.
    public static func indexCalendarHoursBeforeEviction(
        shardID: Int64,
        relativePath: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard isSafeRelativePath(relativePath) else {
            throw LibreReverseShardStoreError.invalidRelativePath(relativePath)
        }
        let alreadyIndexed = try withDatabase(configuration, create: false) { database in
            try scalarInt64(
                database,
                "SELECT COUNT(*) FROM shard_calendar_hour WHERE shardId=\(shardID)"
            ) > 0
        }
        if alreadyIndexed { return }
        let root = configuration.databaseURL.deletingLastPathComponent()
            .standardizedFileURL
        let shardURL = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard shardURL.path.hasPrefix(prefix) else {
            throw LibreReverseShardStoreError.invalidRelativePath(relativePath)
        }
        let shardConfiguration = LibraryDatabaseConfiguration(
            databaseURL: shardURL,
            keyFileURL: configuration.keyFileURL,
            mediaRoot: configuration.mediaRoot
        )
        let shard = try LibraryDatabase.openKeyedDatabase(
            configuration: shardConfiguration
        )
        defer { sqlite3_close(shard) }
        var readStatement: OpaquePointer?
        try prepare(shard, """
            SELECT substr(createdAt,1,13),MIN(createdAt)
              FROM frame GROUP BY substr(createdAt,1,13)
             ORDER BY MIN(createdAt)
            """, &readStatement)
        let read = try unwrap(readStatement, shard)
        defer { sqlite3_finalize(read) }
        var hours: [(String, String)] = []
        while true {
            let status = sqlite3_step(read)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  let hour = string(read, column: 0),
                  let sample = string(read, column: 1) else {
                throw sqliteError(shard)
            }
            hours.append((hour, sample))
        }

        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                var deleteStatement: OpaquePointer?
                try prepare(
                    database,
                    "DELETE FROM shard_calendar_hour WHERE shardId=?",
                    &deleteStatement
                )
                let delete = try unwrap(deleteStatement, database)
                sqlite3_bind_int64(delete, 1, shardID)
                guard sqlite3_step(delete) == SQLITE_DONE else {
                    sqlite3_finalize(delete)
                    throw sqliteError(database)
                }
                sqlite3_finalize(delete)

                var insertStatement: OpaquePointer?
                try prepare(database, """
                    INSERT INTO shard_calendar_hour(shardId,hourKey,sampleCreatedAt)
                    VALUES(?,?,?)
                    """, &insertStatement)
                let insert = try unwrap(insertStatement, database)
                defer { sqlite3_finalize(insert) }
                for (hour, sample) in hours {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    sqlite3_bind_int64(insert, 1, shardID)
                    bind(hour, to: insert, index: 2)
                    bind(sample, to: insert, index: 3)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw sqliteError(database)
                    }
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public static func registerBuildingShard(
        interval: LibreReverseShardInterval,
        generation: Int = 1,
        relativePath: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        guard isSafeRelativePath(relativePath) else {
            throw LibreReverseShardStoreError.invalidRelativePath(relativePath)
        }
        return try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                let overlaps = try scalarInt64(database, """
                    SELECT COUNT(*) FROM library_shard
                     WHERE state!='failed' AND ordinal=\(interval.ordinal)
                       AND generation!=\(generation)
                    """)
                guard overlaps == 0 else {
                    throw LibreReverseShardStoreError.overlappingInterval
                }
                var statement: OpaquePointer?
                try prepare(database, """
                    INSERT INTO library_shard(
                      ordinal,generation,relativePath,state,schemaVersion,keyVersion
                    ) VALUES(?,?,?,'building',41,1)
                    ON CONFLICT(ordinal,generation) DO UPDATE SET
                      relativePath=excluded.relativePath,state='building',lastError=NULL
                    RETURNING id
                    """, &statement)
                let value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, interval.ordinal)
                sqlite3_bind_int64(value, 2, Int64(generation))
                bind(relativePath, to: value, index: 3)
                guard sqlite3_step(value) == SQLITE_ROW else {
                    sqlite3_finalize(value)
                    throw sqliteError(database)
                }
                let id = sqlite3_column_int64(value, 0)
                guard sqlite3_step(value) == SQLITE_DONE else {
                    sqlite3_finalize(value)
                    throw sqliteError(database)
                }
                sqlite3_finalize(value)
                try execute(database, "COMMIT")
                return id
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func markSealedLocal(
        shardID: Int64,
        byteCount: Int64,
        sha256: String,
        frameCount: Int64,
        nodeCount: Int64,
        documentCount: Int64,
        minFrameID: Int64?,
        maxFrameID: Int64?,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard byteCount >= 0, !sha256.isEmpty,
              frameCount >= 0, nodeCount >= 0, documentCount >= 0 else {
            throw LibreReverseShardStoreError.sqlite("invalid shard manifest")
        }
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(database, "SELECT state FROM library_shard WHERE id=?", &statement)
            var value = try unwrap(statement, database)
            sqlite3_bind_int64(value, 1, shardID)
            guard sqlite3_step(value) == SQLITE_ROW,
                  let raw = string(value, column: 0),
                  let state = LibreReverseShardState(rawValue: raw) else {
                sqlite3_finalize(value)
                throw LibreReverseShardStoreError.missingShard(shardID)
            }
            sqlite3_finalize(value)
            guard state == .building else {
                throw LibreReverseShardStoreError.invalidTransition(
                    from: state, to: .sealedLocal
                )
            }
            statement = nil
            try prepare(database, """
                UPDATE library_shard
                   SET state='sealed_local',byteCount=?,sha256=?,frameCount=?,nodeCount=?,
                       documentCount=?,minFrameId=?,maxFrameId=?,sealedAt=?,lastError=NULL
                 WHERE id=? AND state='building'
                """, &statement)
            value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, byteCount)
            bind(sha256, to: value, index: 2)
            sqlite3_bind_int64(value, 3, frameCount)
            sqlite3_bind_int64(value, 4, nodeCount)
            sqlite3_bind_int64(value, 5, documentCount)
            bind(minFrameID, to: value, index: 6)
            bind(maxFrameID, to: value, index: 7)
            bind(databaseString(Date()), to: value, index: 8)
            sqlite3_bind_int64(value, 9, shardID)
            guard sqlite3_step(value) == SQLITE_DONE else { throw sqliteError(database) }
        }
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS shard_metadata(
      id INTEGER PRIMARY KEY CHECK(id=1),epochStart TEXT NOT NULL,
      intervalSeconds INTEGER NOT NULL CHECK(intervalSeconds=2592000),
      routingState TEXT NOT NULL DEFAULT 'monolith'
        CHECK(routingState IN ('monolith','migrating','sharded')),
      activeOrdinal INTEGER
    );
    CREATE TABLE IF NOT EXISTS library_shard(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      ordinal INTEGER NOT NULL,generation INTEGER NOT NULL DEFAULT 1,
      relativePath TEXT,state TEXT NOT NULL,
      schemaVersion INTEGER NOT NULL,keyVersion INTEGER NOT NULL,
      byteCount INTEGER,sha256 TEXT,
      frameCount INTEGER NOT NULL DEFAULT 0,nodeCount INTEGER NOT NULL DEFAULT 0,
      documentCount INTEGER NOT NULL DEFAULT 0,
      minFrameId INTEGER,maxFrameId INTEGER,
      remoteIdentifier TEXT,remoteVersion TEXT,remoteSHA256 TEXT,verifiedAt TEXT,
      sealedAt TEXT,lastAccessAt TEXT,lastError TEXT,
      UNIQUE(ordinal,generation),
      CHECK(state IN ('building','sealed_local','remote_only','rehydrating','failed','corrupt'))
    );
    CREATE INDEX IF NOT EXISTS index_library_shard_on_ordinal_state
      ON library_shard(ordinal,state);
    CREATE TABLE IF NOT EXISTS shard_star(
      frameId INTEGER PRIMARY KEY NOT NULL,createdAt TEXT NOT NULL,
      shardId INTEGER NOT NULL REFERENCES library_shard(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS index_shard_star_on_createdat ON shard_star(createdAt);
    CREATE TABLE IF NOT EXISTS shard_calendar_hour(
      shardId INTEGER NOT NULL REFERENCES library_shard(id) ON DELETE CASCADE,
      hourKey TEXT NOT NULL,sampleCreatedAt TEXT NOT NULL,
      PRIMARY KEY(shardId,hourKey)
    );
    CREATE INDEX IF NOT EXISTS index_shard_calendar_hour_on_sample
      ON shard_calendar_hour(sampleCreatedAt);
    CREATE TABLE IF NOT EXISTS shard_build_progress(
      shardId INTEGER NOT NULL REFERENCES library_shard(id) ON DELETE CASCADE,
      phase TEXT NOT NULL,lastKey INTEGER NOT NULL DEFAULT 0,
      completedRows INTEGER NOT NULL DEFAULT 0,totalRows INTEGER NOT NULL DEFAULT 0,
      updatedAt TEXT,PRIMARY KEY(shardId,phase)
    );
    CREATE TABLE IF NOT EXISTS shard_archive_object(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      shardId INTEGER NOT NULL REFERENCES library_shard(id) ON DELETE CASCADE,
      destinationId INTEGER NOT NULL,
      objectKey TEXT NOT NULL,
      remoteState TEXT NOT NULL DEFAULT 'queued',
      remoteIdentifier TEXT,remoteVersion TEXT,remoteSHA256 TEXT,verifiedAt TEXT,
      sessionIdentifier TEXT,transferredBytes INTEGER NOT NULL DEFAULT 0,
      totalBytes INTEGER NOT NULL DEFAULT 0,attempt INTEGER NOT NULL DEFAULT 0,
      retryAfter TEXT,lastError TEXT,updatedAt TEXT NOT NULL,
      UNIQUE(shardId,destinationId),UNIQUE(destinationId,objectKey),
      CHECK(remoteState IN ('queued','hashing','uploading','verifying','verified','retry_wait','failed','corrupt'))
    );
    CREATE INDEX IF NOT EXISTS index_shard_archive_object_state
      ON shard_archive_object(destinationId,remoteState,retryAfter,id);
    CREATE TABLE IF NOT EXISTS shard_archive_retired_object(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      shardId INTEGER NOT NULL REFERENCES library_shard(id) ON DELETE CASCADE,
      destinationId INTEGER NOT NULL,objectKey TEXT NOT NULL,
      remoteIdentifier TEXT NOT NULL,remoteVersion TEXT,remoteSHA256 TEXT,
      byteCount INTEGER NOT NULL,retiredAt TEXT NOT NULL,
      deleteState TEXT NOT NULL DEFAULT 'queued',attempt INTEGER NOT NULL DEFAULT 0,
      retryAfter TEXT,lastError TEXT,
      UNIQUE(destinationId,remoteIdentifier),
      CHECK(deleteState IN ('queued','retry_wait','failed'))
    );
    CREATE INDEX IF NOT EXISTS index_shard_archive_retired_ready
      ON shard_archive_retired_object(destinationId,deleteState,retryAfter,id);
    CREATE TABLE IF NOT EXISTS video_frame_bounds(
      videoId INTEGER PRIMARY KEY NOT NULL REFERENCES video(id) ON DELETE CASCADE,
      minCreatedAt TEXT NOT NULL,maxCreatedAt TEXT NOT NULL,
      frameCount INTEGER NOT NULL CHECK(frameCount>0)
    );
    CREATE INDEX IF NOT EXISTS index_video_frame_bounds_on_max_createdat
      ON video_frame_bounds(maxCreatedAt);
    """

    private static func insertMetadata(epochStart: Date, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare(database, """
            INSERT INTO shard_metadata(id,epochStart,intervalSeconds,routingState)
            VALUES(1,?,2592000,'monolith')
            """, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        bind(databaseString(epochStart), to: value, index: 1)
        guard sqlite3_step(value) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private static func utcMidnight(_ date: Date) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
    }

    private static func databaseString(_ date: Date) -> String {
        databaseDateFormatter.string(from: date)
    }

    private static func databaseDate(_ text: String) -> Date? {
        databaseDateFormatter.date(from: text)
            ?? databaseDateFormatterWithoutZone.date(from: text)
    }

    private static let databaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()

    private static let databaseDateFormatterWithoutZone: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
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
        try LibreReverseLibraryKey.validate(configuration.keyFileURL)
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(configuration.databaseURL.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage) ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LibreReverseShardStoreError.unableToOpenDatabase(message)
        }
        defer { sqlite3_close(database) }
        let keyStatus = key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }
        guard keyStatus == SQLITE_OK else {
            throw LibreReverseShardStoreError.unableToApplyKey(keyStatus)
        }
        try execute(database, "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON")
        return try operation(database)
    }

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

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(message)
            throw LibreReverseShardStoreError.sqlite(text)
        }
    }

    private static func optionalText(_ database: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
        return string(value, column: 0)
    }

    private static func scalarInt64(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
        return sqlite3_column_int64(value, 0)
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }

    private static func bind(_ value: Int64?, to statement: OpaquePointer, index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, column)
    }

    private static func sqliteError(_ database: OpaquePointer) -> LibreReverseShardStoreError {
        .sqlite(errorMessage(database))
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}
#endif
