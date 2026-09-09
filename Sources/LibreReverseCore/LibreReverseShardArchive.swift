#if os(macOS)
import CSQLCipher
import Darwin
import Foundation

// CSQLCipher also imports the `flock` structure; bind the POSIX function
// explicitly to avoid Swift resolving that structure's initializer.
@_silgen_name("flock")
private func shardFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct LibreReverseShardArchiveObject: Equatable, Sendable {
    public let id: Int64
    public let shardID: Int64
    public let ordinal: Int64
    public let relativePath: String
    public let objectKey: String
    public let integrity: ArchiveIntegrity
    public let remoteState: ArchiveRemoteState
    public let remoteIdentifier: String?
    public let remoteVersion: String?
    public let remoteSHA256: String?
    public let sessionIdentifier: String?
    public let transferredBytes: Int64
}

public struct LibreReverseRemoteShard: Equatable, Sendable {
    public let shardID: Int64
    public let ordinal: Int64
    public let relativePath: String
    public let metadata: RemoteObjectMetadata
    public let integrity: ArchiveIntegrity
}

public struct LibreReverseShardRestoreProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
}

public struct LibreReverseShardArchiveStatus: Equatable, Sendable {
    public let totalObjects: Int
    public let verifiedObjects: Int
    public let queuedObjects: Int
    public let failedObjects: Int
    public let totalBytes: Int64
    public let verifiedBytes: Int64
    public let activeTransferredBytes: Int64
    public let latestVerifiedAt: Date?
}

public struct LibreReverseRetiredShardArchiveObject: Equatable, Sendable {
    public let id: Int64
    public let shardID: Int64
    public let metadata: RemoteObjectMetadata
}

public enum LibreReverseShardArchiveError: Error, LocalizedError, Equatable {
    case shardUnavailable(Int64)
    case localShardMissing(String)
    case localIntegrityMismatch(Int64)
    case unsafeRelativePath(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .shardUnavailable(let ordinal):
            "The archived database period \(ordinal) is not available in the selected archive."
        case .localShardMissing(let path):
            "The local database shard is missing: \(path)"
        case .localIntegrityMismatch(let ordinal):
            "Database shard \(ordinal) failed integrity verification."
        case .unsafeRelativePath(let path):
            "The database shard has an unsafe path: \(path)"
        case .sqlite(let message): message
        }
    }
}

/// Durable provider-neutral state for immutable database-shard objects. Video
/// rows remain in `archive_object`; shards deliberately have their own table so
/// the canonical video foreign-key contract is not weakened or rebuilt.
public enum LibreReverseShardArchiveStore {
    public static func status(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseShardArchiveStatus {
        try withDatabase(configuration, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN remoteState='verified' THEN 1 ELSE 0 END),0),
                       COALESCE(SUM(CASE WHEN remoteState IN
                         ('queued','hashing','uploading','verifying','retry_wait')
                         THEN 1 ELSE 0 END),0),
                       COALESCE(SUM(CASE WHEN remoteState IN ('failed','corrupt')
                         THEN 1 ELSE 0 END),0),
                       COALESCE(SUM(totalBytes),0),
                       COALESCE(SUM(CASE WHEN remoteState='verified'
                         THEN totalBytes ELSE 0 END),0),
                       COALESCE(SUM(CASE WHEN remoteState IN ('uploading','verifying')
                         THEN transferredBytes ELSE 0 END),0),
                       MAX(CASE WHEN remoteState='verified' THEN verifiedAt END)
                  FROM shard_archive_object WHERE destinationId=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW else {
                throw LibreReverseShardArchiveError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            return LibreReverseShardArchiveStatus(
                totalObjects: Int(sqlite3_column_int64(value, 0)),
                verifiedObjects: Int(sqlite3_column_int64(value, 1)),
                queuedObjects: Int(sqlite3_column_int64(value, 2)),
                failedObjects: Int(sqlite3_column_int64(value, 3)),
                totalBytes: sqlite3_column_int64(value, 4),
                verifiedBytes: sqlite3_column_int64(value, 5),
                activeTransferredBytes: sqlite3_column_int64(value, 6),
                latestVerifiedAt: optionalString(value, 7).flatMap {
                    formatter.date(from: $0)
                }
            )
        }
    }

    @discardableResult
    public static func reconcile(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> Int {
        try withDatabase(configuration, session: databaseSession) { database in
            let now = dateString(Date())
            // Empty catalog periods are range metadata, not payload objects.
            // They therefore have neither a local shard nor a remote object.
            try execute(
                database,
                """
                DELETE FROM shard_archive_object
                 WHERE remoteIdentifier IS NULL AND shardId IN (
                   SELECT id FROM library_shard WHERE frameCount=0
                 )
                   AND NOT EXISTS(
                     SELECT 1 FROM shard_archive_retired_object retired
                      WHERE retired.shardId=shard_archive_object.shardId
                   )
                """)
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                INSERT OR IGNORE INTO shard_archive_object(
                  shardId,destinationId,objectKey,remoteState,totalBytes,updatedAt
                )
                SELECT s.id,?,
                       'libraries/' || (SELECT uuid FROM archive_library WHERE id=1) ||
                       '/database-shard/' || printf('%020lld',s.ordinal) || '/' ||
                       COALESCE(s.sha256,printf('%lld',s.id)) || '.sqlite3',
                       'queued',COALESCE(s.byteCount,0),?
                 FROM library_shard s
                 WHERE s.state='sealed_local'
                   AND s.frameCount>0
                   AND s.relativePath IS NOT NULL AND s.sha256 IS NOT NULL
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            bind(now, to: value, index: 2)
            try stepDone(value, database)
            return Int(sqlite3_changes(database))
        }
    }

    public static func nextPending(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseShardArchiveObject? {
        try withDatabase(configuration, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT a.id,a.shardId,s.ordinal,s.relativePath,a.objectKey,
                       s.byteCount,s.sha256,a.remoteState,a.remoteIdentifier,
                       a.remoteVersion,a.remoteSHA256,a.sessionIdentifier,
                       a.transferredBytes
                  FROM shard_archive_object a
                  JOIN library_shard s ON s.id=a.shardId
                 WHERE a.destinationId=? AND s.state='sealed_local' AND (
                       a.remoteState IN ('queued','hashing','uploading','verifying') OR
                       (a.remoteState='retry_wait' AND (a.retryAfter IS NULL OR a.retryAfter<=?))
                 ) AND NOT EXISTS(
                       SELECT 1 FROM meeting_deletion deletion
                        WHERE deletion.shardId=a.shardId
                          AND deletion.state IN ('prepared','replacement_ready')
                 ) AND NOT EXISTS(
                       SELECT 1 FROM meeting_title_update title_update
                        WHERE title_update.shardId=a.shardId
                          AND title_update.state IN ('prepared','replacement_ready')
                 ) ORDER BY a.totalBytes ASC,s.ordinal DESC LIMIT 1
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            bind(dateString(now), to: value, index: 2)
            guard sqlite3_step(value) == SQLITE_ROW else { return nil }
            return try decode(value)
        }
    }

    public static func markHashing(
        id: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try updateState(
            id: id,
            sql: "remoteState='hashing',lastError=NULL,updatedAt='\(dateString(Date()))'",
            configuration: configuration, databaseSession: databaseSession
        )
    }

    public static func checkpoint(
        id: Int64,
        session: ArchiveUploadSession,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE shard_archive_object
                   SET remoteState='uploading',sessionIdentifier=?,transferredBytes=?,
                       totalBytes=?,lastError=NULL,updatedAt=? WHERE id=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(session.identifier, to: value, index: 1)
            sqlite3_bind_int64(value, 2, session.acknowledgedBytes)
            sqlite3_bind_int64(value, 3, session.totalBytes)
            bind(dateString(Date()), to: value, index: 4)
            sqlite3_bind_int64(value, 5, id)
            try stepDone(value, database)
        }
    }

    public static func discardCheckpoint(
        id: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            try execute(
                database,
                """
                UPDATE shard_archive_object SET remoteState='hashing',
                  sessionIdentifier=NULL,transferredBytes=0,updatedAt='\(dateString(Date()))'
                 WHERE id=\(id)
                """)
        }
    }

    public static func recordUploaded(
        id: Int64,
        metadata: RemoteObjectMetadata,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE shard_archive_object SET remoteState='verifying',
                  remoteIdentifier=?,remoteVersion=?,remoteSHA256=?,
                  transferredBytes=totalBytes,updatedAt=? WHERE id=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(metadata.identifier, to: value, index: 1)
            bindOptional(metadata.version, to: value, index: 2)
            bindOptional(metadata.sha256, to: value, index: 3)
            bind(dateString(Date()), to: value, index: 4)
            sqlite3_bind_int64(value, 5, id)
            try stepDone(value, database)
        }
    }

    public static func recordVerified(
        id: Int64,
        verification: RemoteVerification,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        guard verification.matches else { throw ArchiveBackendError.verificationMismatch }
        try withDatabase(configuration, session: databaseSession) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    UPDATE shard_archive_object SET remoteState='verified',
                      remoteIdentifier=?,remoteVersion=?,remoteSHA256=?,verifiedAt=?,
                      sessionIdentifier=NULL,lastError=NULL,updatedAt=? WHERE id=?
                    """, &statement)
                var value = try unwrap(statement, database)
                let now = dateString(Date())
                bind(verification.metadata.identifier, to: value, index: 1)
                bindOptional(verification.metadata.version, to: value, index: 2)
                bindOptional(verification.metadata.sha256, to: value, index: 3)
                bind(now, to: value, index: 4)
                bind(now, to: value, index: 5)
                sqlite3_bind_int64(value, 6, id)
                try stepDone(value, database)
                sqlite3_finalize(value)
                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE library_shard SET remoteIdentifier=?,remoteVersion=?,
                      remoteSHA256=?,verifiedAt=?,lastError=NULL
                     WHERE id=(SELECT shardId FROM shard_archive_object WHERE id=?)
                    """, &statement)
                value = try unwrap(statement, database)
                bind(verification.metadata.identifier, to: value, index: 1)
                bindOptional(verification.metadata.version, to: value, index: 2)
                bindOptional(verification.metadata.sha256, to: value, index: 3)
                bind(now, to: value, index: 4)
                sqlite3_bind_int64(value, 5, id)
                try stepDone(value, database)
                sqlite3_finalize(value)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func recordFailure(
        id: Int64,
        error: Error,
        retryable: Bool,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            let prior = try scalar(
                database, "SELECT attempt FROM shard_archive_object WHERE id=\(id)")
            let attempt = prior + 1
            let retry =
                retryable
                ? dateString(
                    Date().addingTimeInterval(min(3_600, 5 * pow(2, Double(min(9, attempt - 1))))))
                : nil
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE shard_archive_object SET remoteState=?,attempt=?,retryAfter=?,
                  lastError=?,updatedAt=? WHERE id=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(retryable ? "retry_wait" : "failed", to: value, index: 1)
            sqlite3_bind_int64(value, 2, attempt)
            bindOptional(retry, to: value, index: 3)
            bind(error.localizedDescription, to: value, index: 4)
            bind(dateString(Date()), to: value, index: 5)
            sqlite3_bind_int64(value, 6, id)
            try stepDone(value, database)
        }
    }

    public static func retryFailed(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE shard_archive_object SET remoteState='queued',retryAfter=NULL,
                  sessionIdentifier=NULL,transferredBytes=0,lastError=NULL,updatedAt=?
                 WHERE destinationId=? AND remoteState IN ('failed','corrupt')
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(dateString(Date()), to: value, index: 1)
            sqlite3_bind_int64(value, 2, destinationID)
            try stepDone(value, database)
        }
    }

    public static func nextRetiredObjectReadyForRemoval(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseRetiredShardArchiveObject? {
        try withDatabase(configuration, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT retired.id,retired.shardId,retired.remoteIdentifier,
                       retired.remoteVersion,retired.objectKey,retired.byteCount,
                       retired.remoteSHA256
                  FROM shard_archive_retired_object retired
                  JOIN shard_archive_object replacement
                    ON replacement.shardId=retired.shardId
                   AND replacement.destinationId=retired.destinationId
                 WHERE retired.destinationId=?
                   AND replacement.remoteState='verified'
                   AND (retired.deleteState='queued' OR
                        (retired.deleteState='retry_wait' AND
                         (retired.retryAfter IS NULL OR retired.retryAfter<=?)))
                 ORDER BY retired.id LIMIT 1
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            bind(dateString(now), to: value, index: 2)
            guard sqlite3_step(value) == SQLITE_ROW else { return nil }
            let key = ArchiveObjectKey(string(value, 4))
            return .init(
                id: sqlite3_column_int64(value, 0),
                shardID: sqlite3_column_int64(value, 1),
                metadata: .init(
                    identifier: string(value, 2),
                    version: optionalString(value, 3),
                    key: key,
                    byteCount: sqlite3_column_int64(value, 5),
                    sha256: optionalString(value, 6)
                )
            )
        }
    }

    public static func recordRetiredObjectRemoved(
        id: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            try execute(database, "DELETE FROM shard_archive_retired_object WHERE id=\(id)")
        }
    }

    public static func recordRetiredObjectRemovalFailure(
        id: Int64,
        error: Error,
        retryable: Bool,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            let prior = try scalar(
                database,
                "SELECT attempt FROM shard_archive_retired_object WHERE id=\(id)"
            )
            let attempt = prior + 1
            let retry =
                retryable
                ? dateString(
                    Date().addingTimeInterval(
                        min(3_600, 5 * pow(2, Double(min(9, attempt - 1))))
                    ))
                : nil
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE shard_archive_retired_object
                   SET deleteState=?,attempt=?,retryAfter=?,lastError=? WHERE id=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(retryable ? "retry_wait" : "failed", to: value, index: 1)
            sqlite3_bind_int64(value, 2, attempt)
            bindOptional(retry, to: value, index: 3)
            bind(error.localizedDescription, to: value, index: 4)
            sqlite3_bind_int64(value, 5, id)
            try stepDone(value, database)
        }
    }

    public static func remoteShard(
        ordinal: Int64,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseRemoteShard? {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT s.id,s.ordinal,s.relativePath,a.objectKey,a.remoteIdentifier,
                       a.remoteVersion,a.totalBytes,s.sha256,a.remoteSHA256
                  FROM library_shard s JOIN shard_archive_object a ON a.shardId=s.id
                 WHERE s.ordinal=? AND a.destinationId=? AND a.remoteState='verified'
                 ORDER BY s.generation DESC LIMIT 1
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, ordinal)
            sqlite3_bind_int64(value, 2, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW,
                let path = optionalString(value, 2),
                let identifier = optionalString(value, 4),
                let sha = optionalString(value, 7)
            else { return nil }
            let key = ArchiveObjectKey(string(value, 3))
            return .init(
                shardID: sqlite3_column_int64(value, 0),
                ordinal: sqlite3_column_int64(value, 1),
                relativePath: path,
                metadata: .init(
                    identifier: identifier,
                    version: optionalString(value, 5),
                    key: key,
                    byteCount: sqlite3_column_int64(value, 6),
                    sha256: optionalString(value, 8) ?? sha
                ),
                integrity: .init(byteCount: sqlite3_column_int64(value, 6), sha256: sha)
            )
        }
    }

    public static func ordinalsNeedingPolicyRehydration(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [Int64] {
        guard
            let policy = try LibreReverseArchiveStore.policy(
                destinationID: destinationID,
                configuration: configuration
            )
        else { return [] }
        let cutoff = policy.requiredLocalSeconds.map {
            now.addingTimeInterval(-$0)
        }
        return try LibreReverseShardStore.records(configuration: configuration)
            .filter { record in
                guard record.state == .remoteOnly else { return false }
                if let cutoff { return record.interval.end > cutoff }
                return true
            }
            .sorted { $0.interval.ordinal > $1.interval.ordinal }
            .compactMap { record in
                try remoteShard(
                    ordinal: record.interval.ordinal,
                    destinationID: destinationID,
                    configuration: configuration
                ) == nil ? nil : record.interval.ordinal
            }
    }

    public static func setShardState(
        shardID: Int64,
        from: LibreReverseShardState,
        to: LibreReverseShardState,
        error: String? = nil,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database, "UPDATE library_shard SET state=?,lastError=? WHERE id=? AND state=?",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(to.rawValue, to: value, index: 1)
            bindOptional(error, to: value, index: 2)
            sqlite3_bind_int64(value, 3, shardID)
            bind(from.rawValue, to: value, index: 4)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else {
                throw LibreReverseShardArchiveError.sqlite(
                    "database shard residency changed concurrently")
            }
        }
    }

    /// Commit eviction only while the verified payload and remote identity still
    /// match. Network verification may suspend while a shard rewrite completes.
    public static func markRemoteOnlyIfUnchanged(
        _ remote: LibreReverseRemoteShard,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(database, """
                UPDATE library_shard SET state='remote_only',lastError=NULL
                 WHERE id=? AND state='sealed_local' AND relativePath=?
                   AND sha256=? AND byteCount=?
                   AND EXISTS(SELECT 1 FROM shard_archive_object a
                        WHERE a.shardId=library_shard.id AND a.destinationId=?
                          AND a.remoteState='verified' AND a.objectKey=?
                          AND a.remoteIdentifier=? AND a.remoteVersion IS ?
                          AND a.remoteSHA256=? AND a.totalBytes=?)
                   AND NOT EXISTS(SELECT 1 FROM meeting_deletion
                        WHERE shardId=library_shard.id AND state IN ('prepared','replacement_ready'))
                   AND NOT EXISTS(SELECT 1 FROM meeting_title_update
                        WHERE shardId=library_shard.id AND state IN ('prepared','replacement_ready'))
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, remote.shardID)
            bind(remote.relativePath, to: value, index: 2)
            bind(remote.integrity.sha256, to: value, index: 3)
            sqlite3_bind_int64(value, 4, remote.integrity.byteCount)
            sqlite3_bind_int64(value, 5, destinationID)
            bind(remote.metadata.key.value, to: value, index: 6)
            bind(remote.metadata.identifier, to: value, index: 7)
            bindOptional(remote.metadata.version, to: value, index: 8)
            bind(remote.integrity.sha256, to: value, index: 9)
            sqlite3_bind_int64(value, 10, remote.integrity.byteCount)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else {
                throw LibreReverseShardArchiveError.sqlite(
                    "database shard changed during archive verification; local payload was retained")
            }
        }
    }

    private static func updateState(
        id: Int64,
        sql: String,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, session: databaseSession) { database in
            try execute(database, "UPDATE shard_archive_object SET \(sql) WHERE id=\(id)")
        }
    }

    private static func decode(_ value: OpaquePointer) throws -> LibreReverseShardArchiveObject {
        guard let path = optionalString(value, 3), let sha = optionalString(value, 6) else {
            throw LibreReverseShardArchiveError.sqlite("database shard manifest is incomplete")
        }
        return .init(
            id: sqlite3_column_int64(value, 0),
            shardID: sqlite3_column_int64(value, 1),
            ordinal: sqlite3_column_int64(value, 2),
            relativePath: path,
            objectKey: string(value, 4),
            integrity: .init(byteCount: sqlite3_column_int64(value, 5), sha256: sha),
            remoteState: try ArchiveRemoteState.decodePersisted(string(value, 7)),
            remoteIdentifier: optionalString(value, 8),
            remoteVersion: optionalString(value, 9),
            remoteSHA256: optionalString(value, 10),
            sessionIdentifier: optionalString(value, 11),
            transferredBytes: sqlite3_column_int64(value, 12)
        )
    }

    private static func withDatabase<T>(
        _ configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        if let session {
            return try session.withDatabase(configuration: configuration, operation: operation)
        }
        let key = try Data(contentsOf: configuration.keyFileURL)
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(configuration.databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
                == SQLITE_OK,
            let database
        else { throw LibreReverseShardArchiveError.sqlite("unable to open archive catalog") }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) })
                == SQLITE_OK
        else {
            throw LibreReverseShardArchiveError.sqlite("unable to unlock archive catalog")
        }
        try execute(
            database, "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON")
        return try operation(database)
    }

    private static func prepare(
        _ database: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error(database)
        }
    }
    private static func unwrap(_ statement: OpaquePointer?, _ database: OpaquePointer) throws
        -> OpaquePointer
    {
        guard let statement else { throw error(database) }
        return statement
    }
    private static func stepDone(_ statement: OpaquePointer, _ database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
    }
    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let value =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LibreReverseShardArchiveError.sqlite(value)
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
    private static func error(_ database: OpaquePointer) -> LibreReverseShardArchiveError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }
    private static func bind(_ text: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(
            statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private static func bindOptional(_ text: String?, to statement: OpaquePointer, index: Int32) {
        if let text {
            bind(text, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }
    private static func optionalString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column)
    }
    private static func dateString(_ date: Date) -> String { formatter.string(from: date) }
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .iso8601)
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return value
    }()
}

public actor LibreReverseShardArchiveCoordinator {
    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let backend: any ArchiveBackend
    private var running = false
    private(set) var lastRunDatabaseOpenCount = 0

    public init(
        destinationID: Int64, library: LibreReverseLibraryConfiguration, backend: any ArchiveBackend
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
    }

    @discardableResult
    public func runUntilIdle(maxObjects: Int = .max) async throws -> Int {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("ShardUploadBatch", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ShardUploadBatch", interval) }
        guard !running else { return 0 }
        running = true
        // Closed before the caller can replace the primary database.
        let databaseSession = LibreReverseLibraryWriteSession(configuration: library)
        defer {
            lastRunDatabaseOpenCount = databaseSession.connectionOpenCount
            databaseSession.close()
        }
        defer { running = false }
        _ = try LibreReverseShardArchiveStore.reconcile(
            destinationID: destinationID, configuration: library, databaseSession: databaseSession)
        var completed = 0
        while completed < maxObjects,
            let object = try LibreReverseShardArchiveStore.nextPending(
                destinationID: destinationID, configuration: library, databaseSession: databaseSession
            )
        {
            do {
                try await process(object, databaseSession: databaseSession)
                completed += 1
            } catch {
                try? LibreReverseShardArchiveStore.recordFailure(
                    id: object.id, error: error, retryable: Self.isRetryable(error),
                    configuration: library, databaseSession: databaseSession
                )
                if error is CancellationError { throw error }
                throw error
            }
        }
        while let retired = try LibreReverseShardArchiveStore.nextRetiredObjectReadyForRemoval(
            destinationID: destinationID,
            configuration: library, databaseSession: databaseSession
        ) {
            do {
                try await backend.remove(retired.metadata)
                try LibreReverseShardArchiveStore.recordRetiredObjectRemoved(
                    id: retired.id,
                    configuration: library, databaseSession: databaseSession
                )
            } catch {
                try? LibreReverseShardArchiveStore.recordRetiredObjectRemovalFailure(
                    id: retired.id,
                    error: error,
                    retryable: Self.isRetryable(error),
                    configuration: library, databaseSession: databaseSession
                )
                throw error
            }
        }
        return completed
    }

    private func process(_ object: LibreReverseShardArchiveObject, databaseSession: LibreReverseLibraryWriteSession) async throws {
        try Task.checkCancellation()
        try LibreReverseShardArchiveStore.markHashing(id: object.id, configuration: library, databaseSession: databaseSession)
        let local = try safeLocalURL(relativePath: object.relativePath)
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw LibreReverseShardArchiveError.localShardMissing(object.relativePath)
        }
        let integrity = try await ArchiveIntegrityEngine.hashInBackground(file: local)
        guard integrity == object.integrity else {
            throw LibreReverseShardArchiveError.localIntegrityMismatch(object.ordinal)
        }
        let key = ArchiveObjectKey(object.objectKey)
        let remote: RemoteObjectMetadata
        if let existing = try await backend.locate(key) {
            remote = existing
        } else {
            var session: ArchiveUploadSession
            if let identifier = object.sessionIdentifier {
                session = .init(
                    identifier: identifier, key: key,
                    acknowledgedBytes: object.transferredBytes, totalBytes: integrity.byteCount
                )
            } else {
                session = try await beginUpload(object: object, local: local, integrity: integrity)
                try LibreReverseShardArchiveStore.checkpoint(
                    id: object.id, session: session, configuration: library, databaseSession: databaseSession)
            }
            do {
                remote = try await backend.resumeUpload(session, from: local) {
                    [library] checkpoint in
                    try LibreReverseShardArchiveStore.checkpoint(
                        id: object.id, session: checkpoint, configuration: library, databaseSession: databaseSession)
                }.metadata
            } catch ArchiveBackendError.expiredUploadSession {
                try LibreReverseShardArchiveStore.discardCheckpoint(
                    id: object.id, configuration: library, databaseSession: databaseSession)
                session = try await beginUpload(object: object, local: local, integrity: integrity)
                try LibreReverseShardArchiveStore.checkpoint(
                    id: object.id, session: session, configuration: library, databaseSession: databaseSession)
                remote = try await backend.resumeUpload(session, from: local) {
                    [library] checkpoint in
                    try LibreReverseShardArchiveStore.checkpoint(
                        id: object.id, session: checkpoint, configuration: library, databaseSession: databaseSession)
                }.metadata
            }
        }
        try LibreReverseShardArchiveStore.recordUploaded(
            id: object.id, metadata: remote, configuration: library, databaseSession: databaseSession)
        let verification = try await backend.verify(remote, expected: integrity)
        guard verification.matches else { throw ArchiveBackendError.verificationMismatch }
        try LibreReverseShardArchiveStore.recordVerified(
            id: object.id, verification: verification, configuration: library, databaseSession: databaseSession)
    }

    private func beginUpload(
        object: LibreReverseShardArchiveObject,
        local: URL,
        integrity: ArchiveIntegrity
    ) async throws -> ArchiveUploadSession {
        try await backend.beginUpload(
            .init(
                key: .init(object.objectKey), displayName: local.lastPathComponent,
                objectKind: .databaseShard, subjectID: object.shardID,
                relativePath: object.relativePath, contentType: "application/octet-stream",
                integrity: integrity
            ))
    }

    private func safeLocalURL(relativePath: String) throws -> URL {
        let root = library.databaseURL.deletingLastPathComponent().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw LibreReverseShardArchiveError.unsafeRelativePath(relativePath)
        }
        return url
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? ArchiveBackendError {
            switch error {
            case .requestFailed(let status, _):
                return status == 408 || status == 429 || (500...599).contains(status)
            case .rateLimited, .expiredUploadSession, .invalidResponse: return true
            case .unsupportedOperation: return false
            default: return false
            }
        }
        return (error as NSError).domain == NSURLErrorDomain
    }
}

public actor LibreReverseShardResolver {
    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let backend: any ArchiveBackend
    private let fileManager: FileManager
    private var inFlight: [Int64: Task<URL, Error>] = [:]
    private var retired = false

    public init(
        destinationID: Int64,
        library: LibreReverseLibraryConfiguration,
        backend: any ArchiveBackend,
        fileManager: FileManager = .default
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.fileManager = fileManager
    }

    public func cancelAll() { for task in inFlight.values { task.cancel() } }

    public func stopAcceptingWork() {
        retired = true
        cancelAll()
    }

    public func cancelAllAndWait() async {
        stopAcceptingWork()
        let tasks = Array(inFlight.values)
        cancelAll()
        for task in tasks { _ = try? await task.value }
    }

    public func restore(
        ordinal: Int64,
        progress: @escaping @Sendable (LibreReverseShardRestoreProgress) async -> Void
    ) async throws -> URL {
        guard !retired else { throw CancellationError() }
        if let task = inFlight[ordinal] { return try await task.value }
        guard
            let remote = try LibreReverseShardArchiveStore.remoteShard(
                ordinal: ordinal, destinationID: destinationID, configuration: library
            )
        else { throw LibreReverseShardArchiveError.shardUnavailable(ordinal) }
        let canonical = try safeLocalURL(relativePath: remote.relativePath)
        let backend = self.backend
        let fileManager = self.fileManager
        let library = self.library
        let task = Task.detached(priority: .utility) { () throws -> URL in
            let root = library.databaseURL.deletingLastPathComponent()
                .appendingPathComponent("ShardRehydration", isDirectory: true)
            // Establish ownership before changing residency. The OS releases
            // this lock after a crash; a persisted 'rehydrating' row does not.
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let lockURL = root.appendingPathComponent("\(ordinal).lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            while shardFileLock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            defer { _ = shardFileLock(descriptor, LOCK_UN) }
            try Task.checkCancellation()
            // No other resolver owns this shard while the lock is held.
            for entry in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where entry.lastPathComponent.hasPrefix("\(ordinal).") && entry.pathExtension == "partial" {
                try? fileManager.removeItem(at: entry)
            }
            guard let record = try LibreReverseShardStore.records(configuration: library)
                .first(where: { $0.id == remote.shardID }) else {
                throw LibreReverseShardArchiveError.shardUnavailable(ordinal)
            }
            if fileManager.fileExists(atPath: canonical.path) {
                if record.state != .sealedLocal {
                    // Recover a crash between atomic installation and the
                    // residency commit, but never trust unverified bytes.
                    guard try ArchiveIntegrityEngine.hash(file: canonical, checkCancellation: true) == remote.integrity else {
                        throw LibreReverseShardArchiveError.localIntegrityMismatch(ordinal)
                    }
                    try LibreReverseShardArchiveStore.setShardState(
                        shardID: remote.shardID, from: record.state, to: .sealedLocal,
                        configuration: library
                    )
                }
                await backend.releaseDownloadedCopy(remote.metadata, temporaryURL: root.appendingPathComponent("installed"))
                await progress(.init(completedBytes: remote.integrity.byteCount,
                                     totalBytes: remote.integrity.byteCount))
                return canonical
            }
            guard [.remoteOnly, .rehydrating, .sealedLocal].contains(record.state) else {
                throw LibreReverseShardArchiveError.shardUnavailable(ordinal)
            }
            // With exclusive ownership, 'rehydrating' without a canonical file
            // is abandoned work and can safely restart through the normal path.
            try LibreReverseShardArchiveStore.setShardState(
                shardID: remote.shardID, from: record.state, to: .rehydrating,
                configuration: library
            )
            let temporary = root.appendingPathComponent("\(ordinal).\(UUID().uuidString).partial")
            defer { try? fileManager.removeItem(at: temporary) }
            do {
                try Task.checkCancellation()
                try await backend.download(remote.metadata, to: temporary) { bytes in
                    await progress(.init(completedBytes: bytes, totalBytes: remote.integrity.byteCount))
                }
                try Task.checkCancellation()
                let integrity = try ArchiveIntegrityEngine.hash(file: temporary, checkCancellation: true)
                guard integrity == remote.integrity else {
                    throw LibreReverseShardArchiveError.localIntegrityMismatch(ordinal)
                }
                try Task.checkCancellation()
                try fileManager.createDirectory(
                    at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: temporary, to: canonical)
                try LibreReverseShardArchiveStore.setShardState(
                    shardID: remote.shardID, from: .rehydrating, to: .sealedLocal,
                    configuration: library
                )
                await backend.releaseDownloadedCopy(remote.metadata, temporaryURL: temporary)
                return canonical
            } catch {
                try? LibreReverseShardArchiveStore.setShardState(
                    shardID: remote.shardID, from: .rehydrating, to: .remoteOnly,
                    error: error.localizedDescription, configuration: library
                )
                throw error
            }
        }
        inFlight[ordinal] = task
        defer { inFlight[ordinal] = nil }
        return try await task.value
    }

    private func safeLocalURL(relativePath: String) throws -> URL {
        let root = library.databaseURL.deletingLastPathComponent().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw LibreReverseShardArchiveError.unsafeRelativePath(relativePath)
        }
        return url
    }
}

extension LibreReverseShardResolver: LibreReverseMeetingShardRestoring {
    public func restoreForMeetingDeletion(ordinal: Int64) async throws -> URL {
        try await restore(ordinal: ordinal) { _ in }
    }
}

/// Applies the same verified-remote-before-local-removal invariant as video
/// residency. State changes to `remote_only` before deletion; a crash in that
/// small window leaves an extra local copy, and the resolver repairs the state
/// without downloading. It can never leave the catalog claiming local bytes
/// which were already removed.
public actor LibreReverseShardResidencyManager {
    private let destinationID: Int64
    private let library: LibreReverseLibraryConfiguration
    private let backend: any ArchiveBackend
    private let fileManager: FileManager

    public init(
        destinationID: Int64,
        library: LibreReverseLibraryConfiguration,
        backend: any ArchiveBackend,
        fileManager: FileManager = .default
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.fileManager = fileManager
    }

    @discardableResult
    public func evictEligible(now: Date = Date(), limit: Int = 4) async throws -> Int {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("ShardEviction", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ShardEviction", interval) }
        guard limit > 0 else { return 0 }
        // Candidate discovery is synchronous. Close its shared keyed connection
        // before hashing or awaiting the provider; final eviction still rechecks state.
        let candidates: [LibreReverseShardRecord] = try {
            let session = LibreReverseLibraryWriteSession(configuration: library)
            defer { session.close() }
            guard let retention = try LibreReverseArchiveStore.policy(
                destinationID: destinationID, configuration: library, session: session
            )?.requiredLocalSeconds else { return [] }
            let cutoff = now.addingTimeInterval(-retention)
            let records = try LibreReverseShardStore.records(configuration: library, session: session)
                .filter { $0.state == .sealedLocal && $0.interval.end <= cutoff }
            guard !records.isEmpty else { return [] }
            let downloads = try LibreReverseDownloadRequestStore(library: library).load(session: session)
            let protected = Set(downloads.filter {
                $0.completedAt == nil || now.timeIntervalSince($0.completedAt!) < 86_400
            }.compactMap(\.shardOrdinal))
            return Array(records.filter { !protected.contains($0.interval.ordinal) }.prefix(limit))
        }()
        var removed = 0
        for shard in candidates {
            try Task.checkCancellation()
            guard let relativePath = shard.relativePath,
                let remote = try LibreReverseShardArchiveStore.remoteShard(
                    ordinal: shard.interval.ordinal,
                    destinationID: destinationID,
                    configuration: library
                ), remote.shardID == shard.id, remote.relativePath == relativePath
            else { continue }
            let canonical = try safeLocalURL(relativePath: relativePath)
            guard fileManager.fileExists(atPath: canonical.path) else {
                try LibreReverseShardArchiveStore.markRemoteOnlyIfUnchanged(
                    remote, destinationID: destinationID, configuration: library
                )
                removed += 1
                continue
            }
            // Keep the date picker’s day and hour availability index visible for
            // remote-only shards. Persist it while the verified shard is local
            // so browsing availability does not require a payload download.
            try LibreReverseShardStore.indexCalendarHoursBeforeEviction(
                shardID: shard.id,
                relativePath: relativePath,
                configuration: library
            )
            let local = try await ArchiveIntegrityEngine.hashInBackground(file: canonical)
            guard local == remote.integrity else {
                throw LibreReverseShardArchiveError.localIntegrityMismatch(shard.interval.ordinal)
            }
            let verification = try await backend.verify(remote.metadata, expected: local)
            guard verification.matches else { throw ArchiveBackendError.verificationMismatch }
            try LibreReverseShardArchiveStore.markRemoteOnlyIfUnchanged(
                remote, destinationID: destinationID, configuration: library
            )
            do {
                try fileManager.removeItem(at: canonical)
            } catch {
                try? LibreReverseShardArchiveStore.setShardState(
                    shardID: shard.id, from: .remoteOnly, to: .sealedLocal,
                    error: error.localizedDescription, configuration: library
                )
                throw error
            }
            removed += 1
        }
        return removed
    }

    private func safeLocalURL(relativePath: String) throws -> URL {
        let root = library.databaseURL.deletingLastPathComponent().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw LibreReverseShardArchiveError.unsafeRelativePath(relativePath)
        }
        return url
    }
}
#endif
