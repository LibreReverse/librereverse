#if os(macOS)
import CSQLCipher
import Foundation

public struct LibreReverseMeetingContextUpdate: Codable, Equatable, Sendable {
    public let participants: [String]
    public let calendarTitle: String?

    public init(participants: [String], calendarTitle: String?) {
        var seen = Set<String>()
        self.participants = participants.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
        let normalizedCalendar = calendarTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.calendarTitle = normalizedCalendar.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(participantText: String, calendarTitle: String?) {
        self.init(
            participants: participantText.components(
                separatedBy: CharacterSet(charactersIn: ",;\n")
            ),
            calendarTitle: calendarTitle
        )
    }

    public var participantText: String { participants.joined(separator: ", ") }
}

public struct LibreReverseMeetingTitleUpdatePlan: Codable, Equatable, Sendable {
    public let segmentID: Int64
    public let title: String?
    public let shardID: Int64
    public let shardOrdinal: Int64
    public let shardRelativePath: String
    public let shardPriorSHA256: String
    public let shardReplacementSHA256: String?
    public let shardReplacementByteCount: Int64?
}

public enum LibreReverseMeetingTitleUpdateError: Error, LocalizedError, Equatable {
    case meetingNotFound(Int64)
    case remoteShardRequiresRestore(segmentID: Int64, ordinal: Int64)
    case shardArchiveBusy(Int64)
    case shardMutationBusy(Int64)
    case journalConflict(Int64)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id):
            "Meeting \(id) is no longer present in the library."
        case .remoteShardRequiresRestore:
            "The archived meeting must be downloaded before its title can be changed."
        case .shardArchiveBusy:
            "The archived meeting is currently being transferred. Try again when it finishes."
        case .shardMutationBusy:
            "Another meeting in this archived period is currently being changed. Try again when it finishes."
        case .journalConflict:
            "A different title update for this meeting is already being recovered."
        case .database(let message):
            "Meeting title update failed: \(message)"
        }
    }
}

/// Coordinates title changes across the compact primary catalog and immutable
/// SQLCipher shards. A sealed shard is restored when necessary, rewritten by
/// copy-on-write, installed atomically, and queued under a new content-addressed
/// Google Drive object key. The old verified remote object remains retired
/// until the replacement upload verifies.
public struct LibreReverseMeetingTitleUpdateCoordinator: Sendable {
    private let library: LibreReverseLibraryConfiguration
    private let shardRestorer: (any LibreReverseMeetingShardRestoring)?

    public init(
        library: LibreReverseLibraryConfiguration,
        shardRestorer: (any LibreReverseMeetingShardRestoring)? = nil
    ) {
        self.library = library
        self.shardRestorer = shardRestorer
    }

    @discardableResult
    public func update(segmentID: Int64, title: String) async throws -> String? {
        let normalized = LibreReverseMeetingTitleUpdate.normalized(title)
        do {
            if let plan = try LibreReverseMeetingTitleUpdate.prepare(
                segmentID: segmentID,
                title: normalized,
                configuration: library
            ) {
                try LibreReverseMeetingTitleUpdate.commit(
                    plan,
                    configuration: library
                )
            } else {
                _ = try LibreReverseLibraryStore.updateMeetingTitle(
                    segmentID: segmentID,
                    title: normalized ?? "",
                    configuration: library
                )
            }
        } catch LibreReverseMeetingTitleUpdateError.remoteShardRequiresRestore(
            _, let ordinal
        ) {
            guard let shardRestorer else {
                throw LibreReverseMeetingTitleUpdateError.remoteShardRequiresRestore(
                    segmentID: segmentID,
                    ordinal: ordinal
                )
            }
            _ = try await shardRestorer.restoreForMeetingDeletion(ordinal: ordinal)
            guard
                let plan = try LibreReverseMeetingTitleUpdate.prepare(
                    segmentID: segmentID,
                    title: normalized,
                    configuration: library
                )
            else {
                throw LibreReverseMeetingTitleUpdateError.database(
                    "restored meeting unexpectedly returned to primary ownership"
                )
            }
            try LibreReverseMeetingTitleUpdate.commit(plan, configuration: library)
        }
        return normalized
    }

    @discardableResult
    public func updateContext(
        segmentID: Int64,
        participants: [String],
        calendarTitle: String?
    ) async throws -> LibreReverseMeetingContextUpdate {
        let context = LibreReverseMeetingContextUpdate(
            participants: participants,
            calendarTitle: calendarTitle
        )
        try LibreReverseLibraryStore.updateMeetingContext(
            segmentID: segmentID,
            context: context,
            configuration: library
        )
        return context
    }

    @discardableResult
    public func resumePendingUpdates() throws -> Int {
        let plans = try LibreReverseMeetingTitleUpdate.pendingPlans(configuration: library)
        for plan in plans {
            try LibreReverseMeetingTitleUpdate.commit(plan, configuration: library)
        }
        return plans.count
    }
}

public enum LibreReverseMeetingTitleUpdate {
    fileprivate static func normalized(_ title: String) -> String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Returns nil for primary ownership; sealed ownership is durably journaled.
    public static func prepare(
        segmentID: Int64,
        title: String?,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseMeetingTitleUpdatePlan? {
        try LibreReverseArchiveStore.initialize(configuration)
        let facts = try primaryFacts(segmentID: segmentID, configuration: configuration)
        if facts.payloadIsPrimary { return nil }
        let shard = try LibreReverseShardStore.records(configuration: configuration)
            .filter { $0.interval.contains(facts.startDate) }
            .max(by: { $0.generation < $1.generation })
        guard let shard else { throw LibreReverseMeetingTitleUpdateError.meetingNotFound(segmentID) }
        if shard.state == .remoteOnly {
            throw LibreReverseMeetingTitleUpdateError.remoteShardRequiresRestore(
                segmentID: segmentID,
                ordinal: shard.interval.ordinal
            )
        }
        guard shard.state == .sealedLocal,
            let relativePath = shard.relativePath,
            let priorSHA = shard.sha256
        else {
            throw LibreReverseMeetingTitleUpdateError.database(
                "meeting shard is not a verified local sealed shard"
            )
        }
        let plan = LibreReverseMeetingTitleUpdatePlan(
            segmentID: segmentID,
            title: title,
            shardID: shard.id,
            shardOrdinal: shard.interval.ordinal,
            shardRelativePath: relativePath,
            shardPriorSHA256: priorSHA,
            shardReplacementSHA256: nil,
            shardReplacementByteCount: nil
        )
        let shardURL = try safeShardURL(relativePath, configuration: configuration)
        try withKeyedDatabase(url: shardURL, keyFileURL: configuration.keyFileURL) {
            database in
            guard
                try scalar(
                    database,
                    "SELECT COUNT(*) FROM segment WHERE id=\(segmentID) AND type=1"
                ) == 1
            else {
                throw LibreReverseMeetingTitleUpdateError.meetingNotFound(segmentID)
            }
        }
        return try withDatabase(configuration) { database in
            if let pending = try pendingPlan(segmentID: segmentID, database: database) {
                guard pending.title == title else {
                    throw LibreReverseMeetingTitleUpdateError.journalConflict(segmentID)
                }
                return pending
            }
            guard
                try scalar(
                    database,
                    """
                    SELECT COUNT(*) FROM shard_archive_object
                     WHERE shardId=\(shard.id)
                       AND remoteState IN ('hashing','uploading','verifying')
                    """
                ) == 0
            else {
                throw LibreReverseMeetingTitleUpdateError.shardArchiveBusy(segmentID)
            }
            let encoded = try JSONEncoder().encode(plan)
            try execute(database, "BEGIN IMMEDIATE")
            do {
                // A plan owns the entire immutable shard, not just its segment.
                // Another pending title would snapshot the same old hash and
                // become unrecoverable after either plan installs its rewrite.
                guard
                    try scalar(
                        database,
                        """
                        SELECT
                          (SELECT COUNT(*) FROM meeting_deletion
                            WHERE shardId=\(shard.id)
                              AND state IN ('prepared','replacement_ready'))
                          + (SELECT COUNT(*) FROM meeting_title_update
                            WHERE shardId=\(shard.id)
                              AND state IN ('prepared','replacement_ready'))
                        """
                    ) == 0
                else {
                    throw LibreReverseMeetingTitleUpdateError.shardMutationBusy(segmentID)
                }
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT INTO meeting_title_update(
                      segmentId,shardId,planJSON,state,createdAt,updatedAt,lastError
                    ) VALUES(?,?,?,'prepared',?,?,NULL)
                    """,
                    &statement
                )
                let value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, segmentID)
                sqlite3_bind_int64(value, 2, shard.id)
                bind(encoded, to: value, index: 3)
                bind(dateString(Date()), to: value, index: 4)
                bind(dateString(Date()), to: value, index: 5)
                try stepDone(value, database)
                sqlite3_finalize(value)
                try execute(database, "COMMIT")
                return plan
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func pendingPlans(
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [LibreReverseMeetingTitleUpdatePlan] {
        try LibreReverseArchiveStore.initialize(configuration)
        return try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT planJSON FROM meeting_title_update ORDER BY createdAt",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            var plans: [LibreReverseMeetingTitleUpdatePlan] = []
            while sqlite3_step(value) == SQLITE_ROW {
                plans.append(
                    try JSONDecoder().decode(
                        LibreReverseMeetingTitleUpdatePlan.self,
                        from: data(value, column: 0)
                    )
                )
            }
            return plans
        }
    }

    public static func commit(
        _ requested: LibreReverseMeetingTitleUpdatePlan,
        configuration: LibreReverseLibraryConfiguration,
        fileManager: FileManager = .default
    ) throws {
        var plan = try withDatabase(configuration) { database in
            guard
                let pending = try pendingPlan(
                    segmentID: requested.segmentID,
                    database: database
                ), pending.title == requested.title
            else {
                throw LibreReverseMeetingTitleUpdateError.journalConflict(requested.segmentID)
            }
            return pending
        }
        let locations = try rewriteLocations(plan, configuration: configuration)
        let state = try journalState(segmentID: plan.segmentID, configuration: configuration)
        if state == "committed" {
            try finish(plan, locations: locations, configuration: configuration)
            return
        }
        if plan.shardReplacementSHA256 == nil {
            if fileManager.fileExists(atPath: locations.temporary.path) {
                try fileManager.removeItem(at: locations.temporary)
            }
            try fileManager.copyItem(at: locations.canonical, to: locations.temporary)
            try rewriteShard(
                at: locations.temporary,
                segmentID: plan.segmentID,
                title: plan.title,
                keyFileURL: configuration.keyFileURL
            )
            let integrity = try ArchiveIntegrityEngine.hash(file: locations.temporary)
            plan = .init(
                segmentID: plan.segmentID,
                title: plan.title,
                shardID: plan.shardID,
                shardOrdinal: plan.shardOrdinal,
                shardRelativePath: plan.shardRelativePath,
                shardPriorSHA256: plan.shardPriorSHA256,
                shardReplacementSHA256: integrity.sha256,
                shardReplacementByteCount: integrity.byteCount
            )
            let encoded = try JSONEncoder().encode(plan)
            try withDatabase(configuration) { database in
                try execute(database, "BEGIN IMMEDIATE")
                do {
                    guard
                        try pendingPlan(segmentID: plan.segmentID, database: database)?
                            .shardReplacementSHA256 == nil
                    else {
                        throw LibreReverseMeetingTitleUpdateError.journalConflict(plan.segmentID)
                    }
                    var statement: OpaquePointer?
                    try prepare(
                        database,
                        """
                        UPDATE meeting_title_update
                           SET planJSON=?,state='replacement_ready',updatedAt=?
                         WHERE segmentId=?
                        """,
                        &statement
                    )
                    let value = try unwrap(statement, database)
                    bind(encoded, to: value, index: 1)
                    bind(dateString(Date()), to: value, index: 2)
                    sqlite3_bind_int64(value, 3, plan.segmentID)
                    try stepDone(value, database)
                    sqlite3_finalize(value)
                    try execute(database, "COMMIT")
                } catch {
                    try? execute(database, "ROLLBACK")
                    throw error
                }
            }
        }
        try installReplacement(plan, locations: locations, fileManager: fileManager)
        try finalizeCatalog(plan, configuration: configuration)
        try finish(plan, locations: locations, configuration: configuration)
    }

    private struct PrimaryFacts {
        let startDate: Date
        let payloadIsPrimary: Bool
    }

    private struct RewriteLocations {
        let canonical: URL
        let temporary: URL
        let backup: URL
    }

    private static func primaryFacts(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> PrimaryFacts {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT startDate FROM segment WHERE id=? AND type=1",
                &statement
            )
            let value = try unwrap(statement, database)
            sqlite3_bind_int64(value, 1, segmentID)
            guard sqlite3_step(value) == SQLITE_ROW,
                let raw = optionalString(value, column: 0),
                let start = databaseDate(raw)
            else {
                sqlite3_finalize(value)
                throw LibreReverseMeetingTitleUpdateError.meetingNotFound(segmentID)
            }
            sqlite3_finalize(value)
            let payload =
                try scalar(
                    database,
                    """
                    SELECT EXISTS(SELECT 1 FROM frame WHERE segmentId=\(segmentID))
                        OR EXISTS(SELECT 1 FROM doc_segment WHERE segmentId=\(segmentID))
                        OR EXISTS(SELECT 1 FROM audio WHERE segmentId=\(segmentID))
                    """
                ) == 1
            return .init(startDate: start, payloadIsPrimary: payload)
        }
    }

    private static func rewriteLocations(
        _ plan: LibreReverseMeetingTitleUpdatePlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> RewriteLocations {
        let canonical = try safeShardURL(
            plan.shardRelativePath,
            configuration: configuration
        )
        let suffix = ".meeting-title-\(plan.segmentID)"
        return .init(
            canonical: canonical,
            temporary: canonical.appendingPathExtension(suffix + ".pending"),
            backup: canonical.appendingPathExtension(suffix + ".backup")
        )
    }

    private static func rewriteShard(
        at url: URL,
        segmentID: Int64,
        title: String?,
        keyFileURL: URL
    ) throws {
        try withWritableKeyedDatabase(url: url, keyFileURL: keyFileURL) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try updateTitleRows(database, segmentID: segmentID, title: title)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
            var statement: OpaquePointer?
            try prepare(database, "PRAGMA cipher_integrity_check", &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            if sqlite3_step(value) == SQLITE_ROW {
                throw LibreReverseMeetingTitleUpdateError.database(
                    "rewritten shard failed SQLCipher integrity: \(string(value, column: 0))"
                )
            }
        }
    }

    private static func installReplacement(
        _ plan: LibreReverseMeetingTitleUpdatePlan,
        locations: RewriteLocations,
        fileManager: FileManager
    ) throws {
        guard let replacementSHA = plan.shardReplacementSHA256 else {
            throw LibreReverseMeetingTitleUpdateError.database("replacement hash is missing")
        }
        let current = try ArchiveIntegrityEngine.hash(file: locations.canonical)
        if current.sha256 == replacementSHA { return }
        guard current.sha256 == plan.shardPriorSHA256,
            fileManager.fileExists(atPath: locations.temporary.path),
            try ArchiveIntegrityEngine.hash(file: locations.temporary).sha256 == replacementSHA
        else {
            throw LibreReverseMeetingTitleUpdateError.database(
                "shard replacement files do not match their journaled hashes"
            )
        }
        if fileManager.fileExists(atPath: locations.backup.path) {
            try fileManager.removeItem(at: locations.backup)
        }
        _ = try fileManager.replaceItemAt(
            locations.canonical,
            withItemAt: locations.temporary,
            backupItemName: locations.backup.lastPathComponent
        )
        guard
            try ArchiveIntegrityEngine.hash(file: locations.canonical).sha256
                == replacementSHA
        else {
            throw LibreReverseMeetingTitleUpdateError.database(
                "installed shard replacement failed its content hash"
            )
        }
    }

    private static func finalizeCatalog(
        _ plan: LibreReverseMeetingTitleUpdatePlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard let replacementSHA = plan.shardReplacementSHA256,
            let replacementBytes = plan.shardReplacementByteCount
        else {
            throw LibreReverseMeetingTitleUpdateError.database("replacement metadata is incomplete")
        }
        let canonical = try safeShardURL(
            plan.shardRelativePath,
            configuration: configuration
        )
        guard try ArchiveIntegrityEngine.hash(file: canonical).sha256 == replacementSHA else {
            throw LibreReverseMeetingTitleUpdateError.database(
                "installed shard no longer matches the journal"
            )
        }
        try withDatabase(configuration) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                guard try pendingPlan(segmentID: plan.segmentID, database: database) == plan,
                    try scalar(
                        database,
                        """
                        SELECT COUNT(*) FROM library_shard
                         WHERE id=\(plan.shardID) AND state='sealed_local'
                           AND sha256='\(sql(plan.shardPriorSHA256))'
                        """
                    ) == 1
                else {
                    throw LibreReverseMeetingTitleUpdateError.journalConflict(plan.segmentID)
                }
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT OR IGNORE INTO shard_archive_retired_object(
                      shardId,destinationId,objectKey,remoteIdentifier,remoteVersion,
                      remoteSHA256,byteCount,retiredAt
                    )
                    SELECT shardId,destinationId,objectKey,remoteIdentifier,remoteVersion,
                           remoteSHA256,totalBytes,?
                      FROM shard_archive_object
                     WHERE shardId=? AND remoteIdentifier IS NOT NULL
                    """,
                    &statement
                )
                var value = try unwrap(statement, database)
                bind(dateString(Date()), to: value, index: 1)
                sqlite3_bind_int64(value, 2, plan.shardID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE library_shard SET byteCount=?,sha256=?,remoteIdentifier=NULL,
                      remoteVersion=NULL,remoteSHA256=NULL,verifiedAt=NULL,lastError=NULL
                     WHERE id=?
                    """,
                    &statement
                )
                value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, replacementBytes)
                bind(replacementSHA, to: value, index: 2)
                sqlite3_bind_int64(value, 3, plan.shardID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE shard_archive_object
                       SET objectKey='libraries/' ||
                           (SELECT uuid FROM archive_library WHERE id=1) ||
                           '/database-shard/' || printf('%020lld',?) || '/' || ? || '.sqlite3',
                           remoteState='queued',remoteIdentifier=NULL,remoteVersion=NULL,
                           remoteSHA256=NULL,verifiedAt=NULL,sessionIdentifier=NULL,
                           transferredBytes=0,totalBytes=?,attempt=0,retryAfter=NULL,
                           lastError=NULL,updatedAt=?
                     WHERE shardId=?
                    """,
                    &statement
                )
                value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, plan.shardOrdinal)
                bind(replacementSHA, to: value, index: 2)
                sqlite3_bind_int64(value, 3, replacementBytes)
                bind(dateString(Date()), to: value, index: 4)
                sqlite3_bind_int64(value, 5, plan.shardID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                try updateTitleRows(database, segmentID: plan.segmentID, title: plan.title)
                try execute(
                    database,
                    """
                    UPDATE meeting_title_update
                       SET state='committed',updatedAt='\(sql(dateString(Date())))'
                     WHERE segmentId=\(plan.segmentID);
                    """
                )
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private static func finish(
        _ plan: LibreReverseMeetingTitleUpdatePlan,
        locations: RewriteLocations,
        configuration: LibreReverseLibraryConfiguration,
        fileManager: FileManager = .default
    ) throws {
        for url in [locations.temporary, locations.backup]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try withDatabase(configuration) { database in
            try execute(
                database,
                "DELETE FROM meeting_title_update WHERE segmentId=\(plan.segmentID) AND state='committed'"
            )
        }
    }

    private static func updateTitleRows(
        _ database: OpaquePointer,
        segmentID: Int64,
        title: String?
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            database,
            "UPDATE segment SET windowName=? WHERE id=? AND type=1",
            &statement
        )
        var value = try unwrap(statement, database)
        bindOptional(title, to: value, index: 1)
        sqlite3_bind_int64(value, 2, segmentID)
        try stepDone(value, database)
        sqlite3_finalize(value)
        guard sqlite3_changes(database) == 1 else {
            throw LibreReverseMeetingTitleUpdateError.meetingNotFound(segmentID)
        }
        if try tableExists("event", database: database) {
            statement = nil
            try prepare(database, "UPDATE event SET title=? WHERE segmentID=?", &statement)
            value = try unwrap(statement, database)
            bindOptional(title, to: value, index: 1)
            sqlite3_bind_int64(value, 2, segmentID)
            try stepDone(value, database)
            sqlite3_finalize(value)
        }
        statement = nil
        try prepare(
            database,
            """
            UPDATE searchRanking SET title=?
             WHERE rowid IN (
               SELECT docid FROM doc_segment WHERE segmentId=? AND frameId IS NULL
             )
            """,
            &statement
        )
        value = try unwrap(statement, database)
        bind(title ?? "", to: value, index: 1)
        sqlite3_bind_int64(value, 2, segmentID)
        try stepDone(value, database)
        sqlite3_finalize(value)
    }

    private static func journalState(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> String? {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT state FROM meeting_title_update WHERE segmentId=?",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, segmentID)
            guard sqlite3_step(value) == SQLITE_ROW else { return nil }
            return optionalString(value, column: 0)
        }
    }

    private static func pendingPlan(
        segmentID: Int64,
        database: OpaquePointer
    ) throws -> LibreReverseMeetingTitleUpdatePlan? {
        var statement: OpaquePointer?
        try prepare(
            database,
            "SELECT planJSON FROM meeting_title_update WHERE segmentId=?",
            &statement
        )
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, segmentID)
        guard sqlite3_step(value) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(
            LibreReverseMeetingTitleUpdatePlan.self,
            from: data(value, column: 0)
        )
    }

    private static func safeShardURL(
        _ relativePath: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> URL {
        let root = configuration.databaseURL.deletingLastPathComponent().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: url.path) else {
            throw LibreReverseMeetingTitleUpdateError.database("unsafe or missing meeting shard")
        }
        return url
    }

    private static func withDatabase<T>(
        _ configuration: LibreReverseLibraryConfiguration,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let key = try Data(contentsOf: configuration.keyFileURL)
        var raw: OpaquePointer?
        guard
            sqlite3_open_v2(
                configuration.databaseURL.path,
                &raw,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let database = raw
        else {
            throw LibreReverseMeetingTitleUpdateError.database("unable to open library")
        }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({
                sqlite3_key(database, $0.baseAddress, Int32($0.count))
            }) == SQLITE_OK
        else {
            throw LibreReverseMeetingTitleUpdateError.database("unable to unlock library")
        }
        try execute(database, "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON")
        return try operation(database)
    }

    private static func withKeyedDatabase<T>(
        url: URL,
        keyFileURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try openKeyedDatabase(
            url: url,
            keyFileURL: keyFileURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            operation: operation
        )
    }

    private static func withWritableKeyedDatabase<T>(
        url: URL,
        keyFileURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try openKeyedDatabase(
            url: url,
            keyFileURL: keyFileURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        ) { database in
            try execute(database, "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON")
            return try operation(database)
        }
    }

    private static func openKeyedDatabase<T>(
        url: URL,
        keyFileURL: URL,
        flags: Int32,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let key = try Data(contentsOf: keyFileURL)
        var raw: OpaquePointer?
        guard sqlite3_open_v2(url.path, &raw, flags, nil) == SQLITE_OK,
            let database = raw
        else {
            throw LibreReverseMeetingTitleUpdateError.database("unable to open meeting shard")
        }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({
                sqlite3_key(database, $0.baseAddress, Int32($0.count))
            }) == SQLITE_OK
        else {
            throw LibreReverseMeetingTitleUpdateError.database("unable to unlock meeting shard")
        }
        return try operation(database)
    }

    private static func prepare(
        _ database: OpaquePointer,
        _ sql: String,
        _ statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(database)
        }
    }

    private static func unwrap(
        _ statement: OpaquePointer?,
        _ database: OpaquePointer
    ) throws -> OpaquePointer {
        guard let statement else { throw error(database) }
        return statement
    }

    private static func stepDone(
        _ statement: OpaquePointer,
        _ database: OpaquePointer
    ) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LibreReverseMeetingTitleUpdateError.database(text)
        }
    }

    private static func scalar(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { throw error(database) }
        return sqlite3_column_int64(value, 0)
    }

    private static func tableExists(
        _ table: String,
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            &statement
        )
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        bind(table, to: value, index: 1)
        guard sqlite3_step(value) == SQLITE_ROW else { throw error(database) }
        return sqlite3_column_int64(value, 0) == 1
    }

    private static func error(
        _ database: OpaquePointer
    ) -> LibreReverseMeetingTitleUpdateError {
        .database(String(cString: sqlite3_errmsg(database)))
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

    private static func bind(_ value: Data, to statement: OpaquePointer, index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
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

    private static func string(_ statement: OpaquePointer, column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }

    private static func optionalString(
        _ statement: OpaquePointer,
        column: Int32
    ) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : string(statement, column: column)
    }

    private static func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    private static func dateString(_ date: Date) -> String { formatter.string(from: date) }
    private static func databaseDate(_ value: String) -> Date? { formatter.date(from: value) }
    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .iso8601)
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return value
    }()
}
#endif
