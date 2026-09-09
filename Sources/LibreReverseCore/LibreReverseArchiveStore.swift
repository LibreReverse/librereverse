#if os(macOS)
import CSQLCipher
import Foundation

public enum LibreReverseArchiveStoreError: Error, Equatable, LocalizedError {
    case unableToOpenDatabase(String)
    case unableToApplyKey(Int32)
    case sqlite(String)
    case invalidPersistedValue(type: String, value: String)
    case invalidPolicy(String)
    case mediaLeaseUnavailable(Int64)

    public var errorDescription: String? {
        switch self {
        case .unableToOpenDatabase(let message): "Unable to open archive database: \(message)"
        case .unableToApplyKey(let status):
            "Unable to apply archive database key (SQLite status \(status))"
        case .sqlite(let message): "Archive database: \(message)"
        case .invalidPersistedValue(let type, let value):
            "Unknown persisted \(type) value: \(value)"
        case .mediaLeaseUnavailable(let videoID): "Video \(videoID) is not available for a local media lease."
        case .invalidPolicy(let message): "Invalid archive policy: \(message)"
        }
    }
}

public protocol StrictArchivePersistedValue: RawRepresentable, CaseIterable, Sendable
where RawValue == String {}

extension StrictArchivePersistedValue {
    public static func decodePersisted(_ value: String) throws -> Self {
        guard let decoded = Self(rawValue: value) else {
            throw LibreReverseArchiveStoreError.invalidPersistedValue(
                type: String(describing: Self.self),
                value: value
            )
        }
        return decoded
    }
}

public enum ArchiveBackendKind: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case googleDrive = "google_drive"
    case s3Compatible = "s3_compatible"
}

public enum ArchiveCoverageMode: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case allHistory = "all_history"
    case lastDays = "last_days"
    case sinceDate = "since_date"
}

public enum ArchiveRemoteState: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case unscheduled
    case queued
    case hashing
    case uploading
    case uploaded
    case verifying
    case verified
    case retryWait = "retry_wait"
    case failed
    case corrupt
    case deleting
}

public enum ArchiveTransferDirection: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case upload
    case download
}

public enum ArchiveTransferState: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case queued
    case active
    case retryWait = "retry_wait"
    case complete
    case failed
    case cancelled
}

public enum MediaLocalState: String, CaseIterable, Codable, StrictArchivePersistedValue {
    case present
    case evictionStaged = "eviction_staged"
    case absent
    case downloading
    case installing
    case corrupt
}

public struct LibreReverseArchivePolicy: Equatable, Sendable {
    public static let defaultRehydratedCacheBytes: Int64 = 5 * 1024 * 1024 * 1024
    public static let defaultRequiredLocalSeconds: TimeInterval = 30 * 86_400

    public var coverageMode: ArchiveCoverageMode
    public var coverageValue: Double?
    public var continuousArchive: Bool
    public var requiredLocalSeconds: TimeInterval?
    public var rehydratedCacheBytes: Int64
    public var revision: Int64

    public init(
        coverageMode: ArchiveCoverageMode = .allHistory,
        coverageValue: Double? = nil,
        continuousArchive: Bool = true,
        requiredLocalSeconds: TimeInterval? = Self.defaultRequiredLocalSeconds,
        rehydratedCacheBytes: Int64 = Self.defaultRehydratedCacheBytes,
        revision: Int64 = 1
    ) {
        self.coverageMode = coverageMode
        self.coverageValue = coverageValue
        self.continuousArchive = continuousArchive
        self.requiredLocalSeconds = requiredLocalSeconds
        self.rehydratedCacheBytes = rehydratedCacheBytes
        self.revision = revision
    }

    public func coverageStart(now: Date) throws -> Date? {
        switch coverageMode {
        case .allHistory:
            return nil
        case .lastDays:
            guard let coverageValue, coverageValue >= 0 else {
                throw LibreReverseArchiveStoreError.invalidPolicy(
                    "last-days coverage requires a nonnegative day count")
            }
            return now.addingTimeInterval(-coverageValue * 86_400)
        case .sinceDate:
            guard let coverageValue else {
                throw LibreReverseArchiveStoreError.invalidPolicy(
                    "specific-date coverage requires a date")
            }
            return Date(timeIntervalSince1970: coverageValue)
        }
    }
}

public struct LibreReverseArchiveDestination: Equatable, Sendable {
    public let id: Int64
    public let kind: ArchiveBackendKind
    public let displayName: String
    public let enabled: Bool
    public let remoteRoot: String?
}

public struct LibreReverseArchiveObject: Equatable, Sendable {
    public let id: Int64
    public let destinationID: Int64
    public let videoID: Int64
    public let relativePath: String
    public let objectKey: String
    public let byteCount: Int64
    public let localSHA256: String?
    public let remoteIdentifier: String?
    public let remoteState: ArchiveRemoteState

    fileprivate func withState(_ state: ArchiveRemoteState) -> Self {
        .init(
            id: id,
            destinationID: destinationID,
            videoID: videoID,
            relativePath: relativePath,
            objectKey: objectKey,
            byteCount: byteCount,
            localSHA256: localSHA256,
            remoteIdentifier: remoteIdentifier,
            remoteState: state
        )
    }
}

public struct LibreReverseArchiveStatus: Equatable, Sendable {
    public let totalObjects: Int64
    public let queuedObjects: Int64
    public let verifiedObjects: Int64
    public let failedObjects: Int64
    public let totalBytes: Int64
    public let verifiedBytes: Int64
    public let activeTransferredBytes: Int64
    public let rehydrationObjects: Int64
    public let rehydrationBytes: Int64
    public let historicalPendingObjects: Int64
    public let latestObjectState: ArchiveRemoteState?
    /// Newest durable provider verification, not the last UI poll time.
    public let latestVerifiedAt: Date?
}

public struct LibreReverseResidencyForecast: Equatable, Sendable {
    public let bytesSelectedForRemoval: Int64
    public let bytesSafelyEvictable: Int64
    public let bytesWaitingForVerification: Int64
}

public struct LibreReverseArchiveReconciliationBatch: Equatable, Sendable {
    public let insertedCount: Int
    public let lastVideoID: Int64?
}

public struct LibreReverseArchiveTransferCheckpoint: Equatable, Sendable {
    public let sessionIdentifier: String
    public let transferredBytes: Int64
    public let totalBytes: Int64
}

public struct LibreReverseEvictionCandidate: Equatable, Sendable {
    public let archiveObjectID: Int64
    public let videoID: Int64
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let remoteMetadata: RemoteObjectMetadata
}

public struct LibreReverseStagedEviction: Equatable, Sendable {
    public let videoID: Int64
    public let relativePath: String
    public let stagingPath: String
}

public struct LibreReverseRemoteMedia: Equatable, Sendable {
    public let videoID: Int64
    public let relativePath: String
    public let metadata: RemoteObjectMetadata
    public let integrity: ArchiveIntegrity
}

public struct LibreReverseRemoteDayVideo: Equatable, Sendable {
    public let videoID: Int64
    public let relativePath: String
    public let byteCount: Int64

    public init(videoID: Int64, relativePath: String, byteCount: Int64) {
        self.videoID = videoID
        self.relativePath = relativePath
        self.byteCount = byteCount
    }
}

/// Provider-neutral durable archive repository alongside the imported media schema.
public enum LibreReverseArchiveStore {
    public static func initialize(_ configuration: LibreReverseLibraryConfiguration) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute(database, schemaSQL)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    /// Only the installation owner may call this, once during startup before
    /// readers or archive workers begin. Schema initialization is also used by
    /// ordinary journal queries and must never revoke live ownership.
    public static func recoverInterruptedResidency(
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute(database, "UPDATE media_residency SET activeLeases=0")
                // Canonical bytes, if already installed, are recovered by the resolver.
                try execute(database,
                    "UPDATE media_residency SET localState='absent' WHERE localState IN ('downloading','installing')")
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func credentialData(
        account: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Data? {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT value FROM archive_credential WHERE account=?",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(account, to: value, index: 1)
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw sqliteError(database) }
            let count = Int(sqlite3_column_bytes(value, 0))
            guard count > 0, let bytes = sqlite3_column_blob(value, 0) else {
                return Data()
            }
            return Data(bytes: bytes, count: count)
        }
    }

    public static func setCredentialData(
        _ data: Data,
        account: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                INSERT INTO archive_credential(account,value,createdAt,updatedAt)
                VALUES(?,?,?,?)
                ON CONFLICT(account) DO UPDATE SET
                  value=excluded.value,updatedAt=excluded.updatedAt
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            let now = databaseDate(Date())
            bind(account, to: value, index: 1)
            bind(data, to: value, index: 2)
            bind(now, to: value, index: 3)
            bind(now, to: value, index: 4)
            try stepDone(value, database)
        }
    }

    public static func removeCredentialData(
        account: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "DELETE FROM archive_credential WHERE account=?",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(account, to: value, index: 1)
            try stepDone(value, database)
        }
    }

    public static func libraryUUID(configuration: LibreReverseLibraryConfiguration) throws -> String {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(database, "SELECT uuid FROM archive_library WHERE id=1", &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            return string(value, 0)
        }
    }

    @discardableResult
    public static func upsertGoogleDriveDestination(
        displayName: String,
        remoteRoot: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        try upsertDestination(kind: .googleDrive, displayName: displayName,
                              remoteRoot: remoteRoot, configuration: configuration)
    }

    /// Call after draining all work for the previous destination. Remote roots
    /// identify the account/endpoint, bucket and prefix, excluding credentials.
    @discardableResult
    public static func upsertDestination(
        kind: ArchiveBackendKind,
        displayName: String,
        remoteRoot: String,
        credentials: [String: Data] = [:],
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64 {
        try withDatabase(configuration, create: false) { database in
            let now = databaseDate(Date())
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                let old = try readDestination(database, kind: kind)
                let active = try readDestination(database, kind: nil)
                let rootChanged = old != nil && old?.remoteRoot != remoteRoot
                if rootChanged, let old {
                    // Replacing a root discards its remote identifiers. Refuse
                    // while it owns content that has no usable local copy.
                    let missing = try scalarInt64(database, """
                        SELECT COUNT(*) FROM archive_object a
                        LEFT JOIN media_residency m ON m.videoId=a.videoId
                        WHERE a.destinationId=\(old.id) AND COALESCE(m.localState,'absent')!='present'
                        """)
                    let missingShards = try scalarInt64(database, """
                        SELECT COUNT(*) FROM shard_archive_object a
                        JOIN library_shard s ON s.id=a.shardId
                        WHERE a.destinationId=\(old.id) AND s.state IN ('remote_only','rehydrating')
                        """)
                    guard missing == 0 && missingShards == 0 else {
                        throw LibreReverseArchiveStoreError.invalidPolicy(
                            "Restore archived content locally before replacing this destination's remote root.")
                    }
                    try execute(database, "UPDATE archive_destination SET lastValidatedAt=NULL,lastError=NULL WHERE id=\(old.id)")
                    try execute(database, "DELETE FROM archive_transfer WHERE archiveObjectId IN (SELECT id FROM archive_object WHERE destinationId=\(old.id))")
                    try execute(database, "DELETE FROM archive_object WHERE destinationId=\(old.id)")
                    try execute(database, "DELETE FROM shard_archive_object WHERE destinationId=\(old.id)")
                    try execute(database, "DELETE FROM shard_archive_retired_object WHERE destinationId=\(old.id)")
                }
                try execute(database, "UPDATE archive_destination SET enabled=0")
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT INTO archive_destination(kind,displayName,enabled,remoteRoot,createdAt,updatedAt)
                    VALUES(?,?,1,?,?,?)
                    ON CONFLICT(kind) DO UPDATE SET
                      displayName=excluded.displayName, enabled=1,
                      remoteRoot=excluded.remoteRoot,
                      updatedAt=excluded.updatedAt
                    """, &statement)
                let value = try unwrap(statement, database)
                defer { sqlite3_finalize(value) }
                bind(kind.rawValue, to: value, index: 1)
                bind(displayName, to: value, index: 2)
                bind(remoteRoot, to: value, index: 3)
                bind(now, to: value, index: 4)
                bind(now, to: value, index: 5)
                try stepDone(value, database)
                guard let destination = try readDestination(database, kind: kind) else {
                    throw LibreReverseArchiveStoreError.invalidPolicy("destination was not saved")
                }
                let destinationID = destination.id
                if active?.id != destinationID || rootChanged {
                    // Residency describes actual local files, independent of the
                    // provider. Retain present files without inventing local copies.
                    try execute(database, "UPDATE media_residency SET desiredLocal=1,isCache=0")
                    try execute(database, """
                        UPDATE library_shard SET
                          remoteIdentifier=(SELECT remoteIdentifier FROM shard_archive_object a WHERE a.shardId=library_shard.id AND a.destinationId=\(destinationID) AND a.remoteState='verified'),
                          remoteVersion=(SELECT remoteVersion FROM shard_archive_object a WHERE a.shardId=library_shard.id AND a.destinationId=\(destinationID) AND a.remoteState='verified'),
                          remoteSHA256=(SELECT remoteSHA256 FROM shard_archive_object a WHERE a.shardId=library_shard.id AND a.destinationId=\(destinationID) AND a.remoteState='verified'),
                          verifiedAt=(SELECT verifiedAt FROM shard_archive_object a WHERE a.shardId=library_shard.id AND a.destinationId=\(destinationID) AND a.remoteState='verified')
                        """)
                }
                var policy: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT OR IGNORE INTO archive_policy(
                      destinationId,coverageMode,coverageValue,continuousArchive,requiredLocalSeconds,
                      rehydratedCacheBytes,revision,updatedAt
                    ) VALUES(?,'all_history',NULL,1,?, ?,1,?)
                    """, &policy)
                let policyValue = try unwrap(policy, database)
                defer { sqlite3_finalize(policyValue) }
                sqlite3_bind_int64(policyValue, 1, destinationID)
                if kind == .s3Compatible {
                    sqlite3_bind_null(policyValue, 2)
                } else {
                    sqlite3_bind_double(policyValue, 2, LibreReverseArchivePolicy.defaultRequiredLocalSeconds)
                }
                sqlite3_bind_int64(policyValue, 3, LibreReverseArchivePolicy.defaultRehydratedCacheBytes)
                bind(now, to: policyValue, index: 4)
                try stepDone(policyValue, database)
                for (account, data) in credentials {
                    var credential: OpaquePointer?
                    try prepare(database, """
                        INSERT INTO archive_credential(account,value,createdAt,updatedAt)
                        VALUES(?,?,?,?)
                        ON CONFLICT(account) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt
                        """, &credential)
                    let row = try unwrap(credential, database)
                    defer { sqlite3_finalize(row) }
                    bind(account, to: row, index: 1)
                    bind(data, to: row, index: 2)
                    bind(now, to: row, index: 3)
                    bind(now, to: row, index: 4)
                    try stepDone(row, database)
                }
                try execute(database, "COMMIT")
                return destinationID
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func policy(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchivePolicy? {
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT coverageMode,coverageValue,continuousArchive,requiredLocalSeconds,
                       rehydratedCacheBytes,revision
                  FROM archive_policy WHERE destinationId=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw sqliteError(database) }
            return LibreReverseArchivePolicy(
                coverageMode: try ArchiveCoverageMode.decodePersisted(string(value, 0)),
                coverageValue: optionalDouble(value, 1),
                continuousArchive: sqlite3_column_int(value, 2) != 0,
                requiredLocalSeconds: optionalDouble(value, 3),
                rehydratedCacheBytes: sqlite3_column_int64(value, 4),
                revision: sqlite3_column_int64(value, 5)
            )
        }
    }

    public static func activeDestination(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveDestination? {
        try withDatabase(configuration, create: false, session: session) {
            try readDestination($0, kind: nil)
        }
    }

    /// Includes disabled destinations so reconnecting can resume their progress.
    public static func destination(
        kind: ArchiveBackendKind,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveDestination? {
        try withDatabase(configuration, create: false, session: session) {
            try readDestination($0, kind: kind)
        }
    }

    public static func googleDriveDestination(
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveDestination? {
        let destination = try destination(kind: .googleDrive, configuration: configuration, session: session)
        return destination?.enabled == true ? destination : nil
    }

    private static func readDestination(
        _ database: OpaquePointer, kind: ArchiveBackendKind?
    ) throws -> LibreReverseArchiveDestination? {
        var statement: OpaquePointer?
        let filter = kind == nil ? "enabled=1" : "kind=?"
        try prepare(database,
            "SELECT id,kind,displayName,enabled,remoteRoot FROM archive_destination WHERE \(filter) ORDER BY id LIMIT 1",
            &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        if let kind { bind(kind.rawValue, to: value, index: 1) }
        let status = sqlite3_step(value)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteError(database) }
        return .init(id: sqlite3_column_int64(value, 0),
                     kind: try ArchiveBackendKind.decodePersisted(string(value, 1)),
                     displayName: string(value, 2), enabled: sqlite3_column_int(value, 3) != 0,
                     remoteRoot: optionalString(value, 4))
    }

    public static func disableGoogleDriveDestination(configuration: LibreReverseLibraryConfiguration) throws {
        try disableDestination(kind: .googleDrive, configuration: configuration)
    }

    /// A nil kind disables every destination; remote progress is retained.
    public static func disableDestination(
        kind: ArchiveBackendKind? = nil,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            let filter = kind == nil ? "" : " WHERE kind=?"
            try prepare(database, "UPDATE archive_destination SET enabled=0,updatedAt=?\(filter)", &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseDate(Date()), to: value, index: 1)
            if let kind { bind(kind.rawValue, to: value, index: 2) }
            try stepDone(value, database)
        }
    }

    public static func disableDestinations(configuration: LibreReverseLibraryConfiguration) throws {
        try disableDestination(configuration: configuration)
    }

    public static func updatePolicy(
        _ policy: LibreReverseArchivePolicy,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard policy.rehydratedCacheBytes >= 0 else {
            throw LibreReverseArchiveStoreError.invalidPolicy("cache budget cannot be negative")
        }
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE archive_policy SET coverageMode=?,coverageValue=?,continuousArchive=?,
                  requiredLocalSeconds=?,rehydratedCacheBytes=?,revision=revision+1,updatedAt=?
                 WHERE destinationId=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(ArchiveCoverageMode.allHistory.rawValue, to: value, index: 1)
            sqlite3_bind_null(value, 2)
            sqlite3_bind_int(value, 3, 1)
            bindOptional(policy.requiredLocalSeconds, to: value, index: 4)
            sqlite3_bind_int64(value, 5, policy.rehydratedCacheBytes)
            bind(databaseDate(Date()), to: value, index: 6)
            sqlite3_bind_int64(value, 7, destinationID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else {
                throw LibreReverseArchiveStoreError.invalidPolicy("destination does not exist")
            }
        }
    }

    public static func reconcilePolicyStates(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws {
        // Policy lookup and its dependent query share one synchronous unlock.
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        guard let policy = try policy(destinationID: destinationID, configuration: configuration, session: session)
        else {
            throw LibreReverseArchiveStoreError.invalidPolicy("destination has no policy")
        }
        let coverageStart = try policy.coverageStart(now: now)
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE archive_object
                   SET remoteState=CASE
                     WHEN ? IS NULL OR videoId IN (
                       SELECT b.videoId FROM video_frame_bounds b
                        WHERE b.maxCreatedAt>=?
                     ) THEN 'queued' ELSE 'unscheduled' END
                 WHERE destinationId=? AND remoteState IN ('queued','unscheduled','retry_wait')
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            if let coverageStart {
                bind(databaseDate(coverageStart), to: value, index: 1)
                bind(databaseDate(coverageStart), to: value, index: 2)
            } else {
                sqlite3_bind_null(value, 1)
                sqlite3_bind_null(value, 2)
            }
            sqlite3_bind_int64(value, 3, destinationID)
            try stepDone(value, database)
        }
    }

    /// Inserts at most `limit` missing objects and returns their count. A video
    /// is included when any durable Frame intersects coverage; filesystem mtime
    /// never participates.
    @discardableResult
    public static func reconcileEligibleVideos(
        destinationID: Int64,
        afterVideoID: Int64 = 0,
        limit: Int = 250,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int {
        try reconcileEligibleVideoBatch(
            destinationID: destinationID,
            afterVideoID: afterVideoID,
            limit: limit,
            now: now,
            configuration: configuration
        ).insertedCount
    }

    public static func reconcileEligibleVideoBatch(
        destinationID: Int64,
        afterVideoID: Int64 = 0,
        limit: Int = 250,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveReconciliationBatch {
        guard limit > 0 && limit <= 2_000 else {
            throw LibreReverseArchiveStoreError.invalidPolicy("reconciliation batch must be 1...2000")
        }
        // Policy lookup and its dependent query share one synchronous unlock.
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        guard let policy = try policy(destinationID: destinationID, configuration: configuration, session: session)
        else {
            throw LibreReverseArchiveStoreError.invalidPolicy("destination has no policy")
        }
        let coverageStart = try policy.coverageStart(now: now)
        return try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                INSERT OR IGNORE INTO archive_object(
                  destinationId,videoId,relativePath,objectKey,byteCount,remoteState
                )
                SELECT ?,v.id,v.path,
                       'libraries/' || (SELECT uuid FROM archive_library WHERE id=1) ||
                       '/video/' || printf('%020lld',v.id) || '/' || COALESCE(v.xid,printf('%lld',v.id)) || '.mp4',
                       COALESCE(v.fileSize,0),'queued'
                 FROM video v
                 WHERE v.id>?
                   AND COALESCE((SELECT localState FROM media_residency m WHERE m.videoId=v.id),'present')='present'
                   AND NOT EXISTS(
                         SELECT 1 FROM archive_object ao
                          WHERE ao.destinationId=? AND ao.videoId=v.id
                       )
                   AND (? IS NULL OR v.id IN (
                         SELECT b.videoId FROM video_frame_bounds b
                          WHERE b.maxCreatedAt>=?
                       ))
                 ORDER BY v.id ASC LIMIT ?
                RETURNING videoId
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            sqlite3_bind_int64(value, 2, afterVideoID)
            sqlite3_bind_int64(value, 3, destinationID)
            if let coverageStart {
                bind(databaseDate(coverageStart), to: value, index: 4)
                bind(databaseDate(coverageStart), to: value, index: 5)
            } else {
                sqlite3_bind_null(value, 4)
                sqlite3_bind_null(value, 5)
            }
            sqlite3_bind_int(value, 6, Int32(limit))
            var count = 0
            var lastVideoID: Int64?
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                count += 1
                lastVideoID = sqlite3_column_int64(value, 0)
            }
            return .init(insertedCount: count, lastVideoID: lastVideoID)
        }
    }

    public static func objects(
        destinationID: Int64,
        states: Set<ArchiveRemoteState> = [],
        limit: Int = 250,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [LibreReverseArchiveObject] {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            let filter =
                states.isEmpty
                ? ""
                : " AND remoteState IN ("
                    + Array(repeating: "?", count: states.count).joined(separator: ",") + ")"
            try prepare(
                database,
                """
                SELECT id,destinationId,videoId,relativePath,objectKey,byteCount,
                       localSHA256,remoteIdentifier,remoteState
                  FROM archive_object WHERE destinationId=?\(filter)
                 ORDER BY videoId ASC LIMIT ?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            var index: Int32 = 2
            for state in states.sorted(by: { $0.rawValue < $1.rawValue }) {
                bind(state.rawValue, to: value, index: index)
                index += 1
            }
            sqlite3_bind_int(value, index, Int32(limit))
            var result: [LibreReverseArchiveObject] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                result.append(
                    LibreReverseArchiveObject(
                        id: sqlite3_column_int64(value, 0),
                        destinationID: sqlite3_column_int64(value, 1),
                        videoID: sqlite3_column_int64(value, 2),
                        relativePath: string(value, 3),
                        objectKey: string(value, 4),
                        byteCount: sqlite3_column_int64(value, 5),
                        localSHA256: optionalString(value, 6),
                        remoteIdentifier: optionalString(value, 7),
                        remoteState: try ArchiveRemoteState.decodePersisted(string(value, 8))
                    ))
            }
        }
    }

    public static func status(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveStatus {
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT COUNT(*),
                       SUM(CASE WHEN remoteState IN ('queued','hashing','uploading','uploaded','verifying','retry_wait') THEN 1 ELSE 0 END),
                       SUM(CASE WHEN remoteState='verified' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN remoteState IN ('failed','corrupt') THEN 1 ELSE 0 END),
                       COALESCE(SUM(byteCount),0),
                       COALESCE(SUM(CASE WHEN remoteState='verified' THEN byteCount ELSE 0 END),0),
                       COALESCE((
                         SELECT SUM(transfer.transferredBytes)
                           FROM archive_transfer AS transfer
                           JOIN archive_object AS active ON active.id=transfer.archiveObjectId
                          WHERE active.destinationId=? AND active.remoteState!='verified'
                            AND transfer.direction='upload'
                            AND transfer.state IN ('active','retry_wait')
                       ),0),
                       COALESCE((
                         SELECT COUNT(*)
                           FROM media_residency residency
                           JOIN archive_object remote ON remote.videoId=residency.videoId
                          WHERE remote.destinationId=? AND remote.remoteState='verified'
                            AND residency.desiredLocal=1
                            AND residency.localState IN ('absent','downloading','installing')
                       ),0),
                       COALESCE((
                         SELECT SUM(remote.byteCount)
                           FROM media_residency residency
                           JOIN archive_object remote ON remote.videoId=residency.videoId
                          WHERE remote.destinationId=? AND remote.remoteState='verified'
                            AND residency.desiredLocal=1
                            AND residency.localState IN ('absent','downloading','installing')
                       ),0),
                       COALESCE(SUM(CASE
                         WHEN videoId!=(SELECT MAX(id) FROM video)
                          AND remoteState!='verified' THEN 1 ELSE 0 END),0),
                       MAX(CASE WHEN remoteState='verified' THEN verifiedAt END)
                  FROM archive_object
                 WHERE destinationId=? AND remoteState!='unscheduled'
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            sqlite3_bind_int64(value, 2, destinationID)
            sqlite3_bind_int64(value, 3, destinationID)
            sqlite3_bind_int64(value, 4, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            let latestState: ArchiveRemoteState? = try {
                var latest: OpaquePointer?
                try prepare(
                    database,
                    """
                    SELECT ao.remoteState FROM video v
                      LEFT JOIN archive_object ao
                        ON ao.videoId=v.id AND ao.destinationId=?
                     ORDER BY v.id DESC LIMIT 1
                    """, &latest)
                let row = try unwrap(latest, database)
                defer { sqlite3_finalize(row) }
                sqlite3_bind_int64(row, 1, destinationID)
                guard sqlite3_step(row) == SQLITE_ROW,
                    let stored = optionalString(row, 0)
                else { return nil }
                return try ArchiveRemoteState.decodePersisted(stored)
            }()
            return LibreReverseArchiveStatus(
                totalObjects: sqlite3_column_int64(value, 0),
                queuedObjects: sqlite3_column_int64(value, 1),
                verifiedObjects: sqlite3_column_int64(value, 2),
                failedObjects: sqlite3_column_int64(value, 3),
                totalBytes: sqlite3_column_int64(value, 4),
                verifiedBytes: sqlite3_column_int64(value, 5),
                activeTransferredBytes: sqlite3_column_int64(value, 6),
                rehydrationObjects: sqlite3_column_int64(value, 7),
                rehydrationBytes: sqlite3_column_int64(value, 8),
                historicalPendingObjects: sqlite3_column_int64(value, 9),
                latestObjectState: latestState,
                latestVerifiedAt: optionalString(value, 10).flatMap {
                    databaseDateFormatter.date(from: $0)
                }
            )
        }
    }

    public static func claimNextQueuedObject(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseArchiveObject? {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    SELECT id,destinationId,videoId,relativePath,objectKey,byteCount,
                           localSHA256,remoteIdentifier,remoteState
                      FROM archive_object
                     WHERE destinationId=? AND (
                           remoteState='queued' OR (
                             remoteState='retry_wait' AND NOT EXISTS (
                               SELECT 1 FROM archive_transfer AS retry
                                WHERE retry.archiveObjectId=archive_object.id
                                  AND retry.direction='upload'
                                  AND retry.state='retry_wait'
                                  AND retry.retryAfter>?
                             )
                           )
                     )
                     ORDER BY videoId LIMIT 1
                    """, &statement)
                let row = try unwrap(statement, database)
                sqlite3_bind_int64(row, 1, destinationID)
                bind(databaseDate(now), to: row, index: 2)
                let status = sqlite3_step(row)
                if status == SQLITE_DONE {
                    sqlite3_finalize(row)
                    try execute(database, "COMMIT")
                    return nil
                }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                let object = try decodeObject(row)
                sqlite3_finalize(row)
                try execute(
                    database,
                    "UPDATE archive_object SET remoteState='hashing',lastError=NULL WHERE id=\(object.id) AND remoteState IN ('queued','retry_wait')"
                )
                guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
                try execute(database, "COMMIT")
                return object.withState(.hashing)
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func recoverInterruptedWork(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE archive_object
                   SET remoteState='retry_wait',lastError='Interrupted archive work recovered after launch'
                 WHERE destinationId=? AND remoteState IN ('hashing','uploading','uploaded','verifying')
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            try stepDone(value, database)
        }
    }

    /// Explicit user retry. Automatic transient retries continue to honor
    /// their persisted backoff; this transition is reserved for the Settings
    /// action after the user has corrected a terminal condition.
    public static func retryFailedObjects(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    UPDATE archive_object SET remoteState='queued',lastError=NULL
                     WHERE destinationId=? AND remoteState IN ('failed','corrupt')
                    """, &statement)
                let value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, destinationID)
                try stepDone(value, database)
                sqlite3_finalize(value)
                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE archive_transfer SET state='cancelled',retryAfter=NULL,updatedAt=?
                     WHERE archiveObjectId IN (
                       SELECT id FROM archive_object WHERE destinationId=?
                     ) AND direction='upload' AND state='failed'
                    """, &statement)
                let transfer = try unwrap(statement, database)
                bind(databaseDate(Date()), to: transfer, index: 1)
                sqlite3_bind_int64(transfer, 2, destinationID)
                try stepDone(transfer, database)
                sqlite3_finalize(transfer)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func reconcileDesiredResidency(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws {
        // Policy lookup and its dependent query share one synchronous unlock.
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        guard let policy = try policy(destinationID: destinationID, configuration: configuration, session: session)
        else {
            throw LibreReverseArchiveStoreError.invalidPolicy("destination has no policy")
        }
        try withDatabase(configuration, create: false, session: session) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute(
                    database,
                    "INSERT OR IGNORE INTO media_residency(videoId,localState,desiredLocal) SELECT id,'present',1 FROM video"
                )
                var statement: OpaquePointer?
                if let seconds = policy.requiredLocalSeconds {
                    let cutoff = databaseDate(now.addingTimeInterval(-seconds))
                    try prepare(
                        database,
                        """
                        UPDATE media_residency
                           SET desiredLocal=CASE WHEN videoId IN (
                                 SELECT b.videoId FROM video_frame_bounds b
                                  WHERE b.maxCreatedAt>=?
                               ) THEN 1 ELSE 0 END,
                               isCache=CASE WHEN videoId IN (
                                 SELECT b.videoId FROM video_frame_bounds b
                                  WHERE b.maxCreatedAt>=?
                               ) THEN 0 ELSE isCache END
                        """, &statement)
                    let value = try unwrap(statement, database)
                    bind(cutoff, to: value, index: 1)
                    bind(cutoff, to: value, index: 2)
                    try stepDone(value, database)
                    sqlite3_finalize(value)
                } else {
                    try execute(database, "UPDATE media_residency SET desiredLocal=1,isCache=0")
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func evictionCandidates(
        destinationID: Int64,
        limit: Int = 100,
        accessedBefore: Date = Date().addingTimeInterval(-60),
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseEvictionCandidate] {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT ao.id,v.id,v.path,ao.byteCount,ao.localSHA256,
                       ao.remoteIdentifier,ao.remoteVersion,ao.objectKey,ao.remoteSHA256
                  FROM media_residency mr
                  JOIN video v ON v.id=mr.videoId
                  JOIN archive_object ao ON ao.videoId=v.id AND ao.destinationId=?
                 WHERE mr.localState='present' AND mr.desiredLocal=0 AND mr.activeLeases=0
                   AND (mr.lastAccessAt IS NULL OR mr.lastAccessAt<?)
                   AND (mr.isCache=0 OR mr.cacheRetainUntil IS NULL OR mr.cacheRetainUntil<=?)
                   AND ao.remoteState='verified' AND ao.localSHA256 IS NOT NULL
                   AND ao.remoteSHA256=ao.localSHA256
                 ORDER BY mr.isCache ASC,mr.lastAccessAt IS NOT NULL,mr.lastAccessAt,v.id LIMIT ?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            bind(databaseDate(accessedBefore), to: value, index: 2)
            bind(databaseDate(now), to: value, index: 3)
            sqlite3_bind_int(value, 4, Int32(limit))
            var result: [LibreReverseEvictionCandidate] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                guard let remoteIdentifier = optionalString(value, 5),
                    let remoteSHA256 = optionalString(value, 8)
                else {
                    throw sqliteError(database)
                }
                let key = ArchiveObjectKey(string(value, 7))
                let byteCount = sqlite3_column_int64(value, 3)
                result.append(
                    .init(
                        archiveObjectID: sqlite3_column_int64(value, 0),
                        videoID: sqlite3_column_int64(value, 1),
                        relativePath: string(value, 2),
                        byteCount: byteCount,
                        sha256: string(value, 4),
                        remoteMetadata: .init(
                            identifier: remoteIdentifier,
                            version: optionalString(value, 6),
                            key: key,
                            byteCount: byteCount,
                            sha256: remoteSHA256
                        )
                    ))
            }
        }
    }

    public static func evictionBytesRequired(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Int64 {
        // Policy lookup and its dependent query share one synchronous unlock.
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        guard let policy = try policy(destinationID: destinationID, configuration: configuration, session: session)
        else { throw LibreReverseArchiveStoreError.invalidPolicy("destination has no policy") }
        return try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT COALESCE(SUM(CASE WHEN mr.isCache=0 THEN ao.byteCount ELSE 0 END),0),
                       COALESCE(SUM(CASE WHEN mr.isCache=1
                         AND (mr.cacheRetainUntil IS NULL OR mr.cacheRetainUntil<=?)
                         THEN ao.byteCount ELSE 0 END),0)
                  FROM media_residency mr
                  JOIN archive_object ao ON ao.videoId=mr.videoId AND ao.destinationId=?
                 WHERE mr.localState='present' AND mr.desiredLocal=0
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseDate(now), to: value, index: 1)
            sqlite3_bind_int64(value, 2, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            let originalBytes = sqlite3_column_int64(value, 0)
            let cacheBytes = sqlite3_column_int64(value, 1)
            return originalBytes + max(0, cacheBytes - policy.rehydratedCacheBytes)
        }
    }

    public static func residencyForecast(
        destinationID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> LibreReverseResidencyForecast {
        // Policy lookup and its dependent query share one synchronous unlock.
        let ownedSession = session == nil
            ? LibreReverseLibraryWriteSession(configuration: configuration) : nil
        defer { ownedSession?.close() }
        let session = session ?? ownedSession
        guard let policy = try policy(destinationID: destinationID, configuration: configuration, session: session)
        else { throw LibreReverseArchiveStoreError.invalidPolicy("destination has no policy") }
        return try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT
                  COALESCE(SUM(CASE WHEN mr.isCache=0 THEN COALESCE(v.fileSize,ao.byteCount,0) ELSE 0 END),0),
                  COALESCE(SUM(CASE WHEN mr.isCache=1
                    AND (mr.cacheRetainUntil IS NULL OR mr.cacheRetainUntil<=?)
                    THEN COALESCE(v.fileSize,ao.byteCount,0) ELSE 0 END),0),
                  COALESCE(SUM(CASE WHEN mr.isCache=0 AND ao.remoteState='verified'
                    AND mr.lastError IS NULL AND ao.localSHA256 IS NOT NULL AND ao.remoteSHA256=ao.localSHA256
                    THEN COALESCE(v.fileSize,ao.byteCount,0) ELSE 0 END),0),
                  COALESCE(SUM(CASE WHEN mr.isCache=1
                    AND (mr.cacheRetainUntil IS NULL OR mr.cacheRetainUntil<=?)
                    AND ao.remoteState='verified'
                    AND mr.lastError IS NULL AND ao.localSHA256 IS NOT NULL AND ao.remoteSHA256=ao.localSHA256
                    THEN COALESCE(v.fileSize,ao.byteCount,0) ELSE 0 END),0)
                  FROM media_residency mr
                  JOIN video v ON v.id=mr.videoId
                  LEFT JOIN archive_object ao ON ao.videoId=mr.videoId AND ao.destinationId=?
                 WHERE mr.localState='present' AND mr.desiredLocal=0
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseDate(now), to: value, index: 1)
            bind(databaseDate(now), to: value, index: 2)
            sqlite3_bind_int64(value, 3, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            let original = sqlite3_column_int64(value, 0)
            let cached = sqlite3_column_int64(value, 1)
            let safeOriginal = sqlite3_column_int64(value, 2)
            let safeCached = sqlite3_column_int64(value, 3)
            let cacheExcess = max(0, cached - policy.rehydratedCacheBytes)
            let selected = original + cacheExcess
            let safe = min(original, safeOriginal) + min(cacheExcess, safeCached)
            return .init(
                bytesSelectedForRemoval: selected,
                bytesSafelyEvictable: safe,
                bytesWaitingForVerification: max(0, selected - safe)
            )
        }
    }

    public static func nextEvictionEligibilityDate(
        destinationID: Int64,
        handoffGraceSeconds: TimeInterval = 60,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Date? {
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT MIN(mr.lastAccessAt)
                  FROM media_residency mr
                  JOIN archive_object ao ON ao.videoId=mr.videoId AND ao.destinationId=?
                 WHERE mr.localState='present' AND mr.desiredLocal=0 AND mr.activeLeases=0
                   AND mr.lastAccessAt IS NOT NULL
                   AND ao.remoteState='verified' AND ao.localSHA256 IS NOT NULL
                   AND ao.remoteSHA256=ao.localSHA256
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW,
                let stored = optionalString(value, 0),
                let accessed = databaseDateFormatter.date(from: stored)
            else { return nil }
            return accessed.addingTimeInterval(max(0, handoffGraceSeconds))
        }
    }

    public static func stageEviction(
        candidate: LibreReverseEvictionCandidate,
        stagingPath: String,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> Bool {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                UPDATE media_residency SET localState='eviction_staged',stagingPath=?,lastError=NULL
                 WHERE videoId=? AND localState='present' AND desiredLocal=0 AND activeLeases=0
                   AND EXISTS(
                     SELECT 1 FROM archive_object ao
                      WHERE ao.videoId=? AND ao.destinationId=? AND ao.remoteState='verified'
                        AND ao.byteCount=? AND ao.localSHA256=? AND ao.remoteSHA256=ao.localSHA256
                   )
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(stagingPath, to: value, index: 1)
            sqlite3_bind_int64(value, 2, candidate.videoID)
            sqlite3_bind_int64(value, 3, candidate.videoID)
            sqlite3_bind_int64(value, 4, destinationID)
            sqlite3_bind_int64(value, 5, candidate.byteCount)
            bind(candidate.sha256, to: value, index: 6)
            try stepDone(value, database)
            return sqlite3_changes(database) == 1
        }
    }

    public static func recordResidencyError(
        videoID: Int64,
        message: String,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database, "UPDATE media_residency SET lastError=? WHERE videoId=?", &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(message, to: value, index: 1)
            sqlite3_bind_int64(value, 2, videoID)
            try stepDone(value, database)
        }
    }

    public static func stagedEvictions(
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> [LibreReverseStagedEviction] {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT mr.videoId,v.path,mr.stagingPath FROM media_residency mr JOIN video v ON v.id=mr.videoId WHERE mr.localState='eviction_staged' AND mr.stagingPath IS NOT NULL",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            var result: [LibreReverseStagedEviction] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                result.append(
                    .init(
                        videoID: sqlite3_column_int64(value, 0),
                        relativePath: string(value, 1),
                        stagingPath: string(value, 2)
                    ))
            }
        }
    }

    public static func finishEviction(
        videoID: Int64,
        localState: MediaLocalState,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        guard localState == .present || localState == .absent else {
            throw LibreReverseArchiveStoreError.invalidPersistedValue(
                type: "eviction recovery state", value: localState.rawValue)
        }
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET localState=?,stagingPath=NULL,lastError=NULL WHERE videoId=? AND localState='eviction_staged'",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(localState.rawValue, to: value, index: 1)
            sqlite3_bind_int64(value, 2, videoID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func adjustLease(
        videoID: Int64,
        delta: Int,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        guard delta == 1 || delta == -1 else {
            throw LibreReverseArchiveStoreError.invalidPolicy("lease delta must be +1 or -1")
        }
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET activeLeases=activeLeases+?,lastAccessAt=? WHERE videoId=? AND activeLeases+?>=0 AND (?<0 OR localState='present')",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int(value, 1, Int32(delta))
            bind(databaseDate(Date()), to: value, index: 2)
            sqlite3_bind_int64(value, 3, videoID)
            sqlite3_bind_int(value, 4, Int32(delta))
            sqlite3_bind_int(value, 5, Int32(delta))
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else {
                throw LibreReverseArchiveStoreError.mediaLeaseUnavailable(videoID)
            }
        }
    }

    public static func verifiedRemoteMedia(
        videoID: Int64,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseRemoteMedia? {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT ao.remoteIdentifier,ao.remoteVersion,ao.objectKey,ao.byteCount,
                       ao.remoteSHA256,v.path
                  FROM archive_object ao JOIN video v ON v.id=ao.videoId
                 WHERE ao.videoId=? AND ao.destinationId=? AND ao.remoteState='verified'
                   AND ao.remoteIdentifier IS NOT NULL AND ao.localSHA256=ao.remoteSHA256
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, videoID)
            sqlite3_bind_int64(value, 2, destinationID)
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW,
                let identifier = optionalString(value, 0),
                let sha256 = optionalString(value, 4)
            else { throw sqliteError(database) }
            let key = ArchiveObjectKey(string(value, 2))
            let byteCount = sqlite3_column_int64(value, 3)
            return .init(
                videoID: videoID,
                relativePath: string(value, 5),
                metadata: .init(
                    identifier: identifier,
                    version: optionalString(value, 1),
                    key: key,
                    byteCount: byteCount,
                    sha256: sha256
                ),
                integrity: .init(byteCount: byteCount, sha256: sha256)
            )
        }
    }

    public static func videosNeedingRehydration(
        destinationID: Int64,
        limit: Int = 25,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> [Int64] {
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT mr.videoId
                  FROM media_residency mr
                  JOIN archive_object ao ON ao.videoId=mr.videoId AND ao.destinationId=?
                 WHERE mr.desiredLocal=1 AND mr.localState='absent'
                   AND ao.remoteState='verified'
                 ORDER BY mr.videoId DESC LIMIT ?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            sqlite3_bind_int(value, 2, Int32(limit))
            var result: [Int64] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                result.append(sqlite3_column_int64(value, 0))
            }
        }
    }

    public static func verifiedRemoteVideos(
        in interval: DateInterval,
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [LibreReverseRemoteDayVideo] {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT ao.videoId,ao.relativePath,ao.byteCount
                  FROM archive_object ao
                 WHERE ao.destinationId=? AND ao.remoteState='verified'
                   AND EXISTS(
                         SELECT 1 FROM video_frame_bounds b
                          WHERE b.videoId=ao.videoId
                            AND b.maxCreatedAt>=? AND b.minCreatedAt<?
                       )
                 ORDER BY (
                           SELECT b.minCreatedAt FROM video_frame_bounds b
                            WHERE b.videoId=ao.videoId
                          ) ASC,ao.videoId ASC
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            bind(databaseDate(interval.start), to: value, index: 2)
            bind(databaseDate(interval.end), to: value, index: 3)
            var result: [LibreReverseRemoteDayVideo] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                result.append(
                    .init(
                        videoID: sqlite3_column_int64(value, 0),
                        relativePath: string(value, 1),
                        byteCount: sqlite3_column_int64(value, 2)
                    ))
            }
        }
    }

    public static func verifiedRemoteVideos(
        centeredOn videoID: Int64,
        destinationID: Int64,
        limit: Int = 9,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> [LibreReverseRemoteDayVideo] {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT ao.videoId,ao.relativePath,ao.byteCount
                  FROM archive_object ao
                 WHERE ao.destinationId=? AND ao.remoteState='verified'
                 ORDER BY abs(ao.videoId-?),ao.videoId DESC LIMIT ?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            sqlite3_bind_int64(value, 2, videoID)
            sqlite3_bind_int(value, 3, Int32(max(1, limit)))
            var result: [LibreReverseRemoteDayVideo] = []
            while true {
                let status = sqlite3_step(value)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw sqliteError(database) }
                result.append(.init(
                    videoID: sqlite3_column_int64(value, 0),
                    relativePath: string(value, 1),
                    byteCount: sqlite3_column_int64(value, 2)
                ))
            }
        }
    }

    public static func markRehydrated(
        videoID: Int64,
        now: Date = Date(),
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET localState='present',lastAccessAt=?,localVerifiedAt=?,cacheRetainUntil=CASE WHEN isCache=1 THEN ? ELSE cacheRetainUntil END,stagingPath=NULL,lastError=NULL WHERE videoId=? AND localState IN ('present','absent','corrupt','installing')",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            let timestamp = databaseDate(now)
            let retainUntil = now.addingTimeInterval(LibreReverseShardInterval.duration)
            bind(timestamp, to: value, index: 1)
            bind(timestamp, to: value, index: 2)
            bind(databaseDate(retainUntil), to: value, index: 3)
            sqlite3_bind_int64(value, 4, videoID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func beginRehydration(
        videoID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET localState='downloading',isCache=CASE WHEN desiredLocal=0 THEN 1 ELSE 0 END,lastError=NULL WHERE videoId=? AND localState IN ('absent','present','corrupt') AND activeLeases=0",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, videoID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func markRehydrationInstalling(
        videoID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try setRehydrationState(
            videoID: videoID,
            from: .downloading,
            to: .installing,
            error: nil,
            configuration: configuration
        )
    }

    public static func recordRehydrationFailure(
        videoID: Int64,
        error: Error,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET localState='absent',lastError=? WHERE videoId=? AND localState IN ('downloading','installing')",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(error.localizedDescription, to: value, index: 1)
            sqlite3_bind_int64(value, 2, videoID)
            try stepDone(value, database)
        }
    }

    public static func recordVerifiedRemoteUnavailable(
        videoID: Int64,
        destinationID: Int64,
        error: Error,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database,
                    "UPDATE archive_object SET remoteState='failed',lastError=? WHERE videoId=? AND destinationId=? AND remoteState='verified'",
                    &statement)
                var value = try unwrap(statement, database)
                bind(error.localizedDescription, to: value, index: 1)
                sqlite3_bind_int64(value, 2, videoID)
                sqlite3_bind_int64(value, 3, destinationID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                statement = nil
                try prepare(
                    database, "UPDATE media_residency SET lastError=? WHERE videoId=?", &statement)
                value = try unwrap(statement, database)
                bind(error.localizedDescription, to: value, index: 1)
                sqlite3_bind_int64(value, 2, videoID)
                try stepDone(value, database)
                sqlite3_finalize(value)
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private static func setRehydrationState(
        videoID: Int64,
        from: MediaLocalState,
        to: MediaLocalState,
        error: String?,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        try withDatabase(configuration, create: false) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE media_residency SET localState=?,lastError=? WHERE videoId=? AND localState=?",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(to.rawValue, to: value, index: 1)
            bindOptional(error, to: value, index: 2)
            sqlite3_bind_int64(value, 3, videoID)
            bind(from.rawValue, to: value, index: 4)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func recordHashedObject(
        objectID: Int64,
        integrity: ArchiveIntegrity,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE archive_object SET byteCount=?,localSHA256=?,remoteState='uploading',lastError=NULL WHERE id=? AND remoteState='hashing'",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, integrity.byteCount)
            bind(integrity.sha256, to: value, index: 2)
            sqlite3_bind_int64(value, 3, objectID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func uploadCheckpoint(
        objectID: Int64,
        key: ArchiveObjectKey,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws -> ArchiveUploadSession? {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT sessionIdentifier,transferredBytes,totalBytes FROM archive_transfer WHERE archiveObjectId=? AND direction='upload' AND state IN ('active','retry_wait') AND sessionIdentifier IS NOT NULL AND sessionIdentifier!='' ORDER BY id DESC LIMIT 1",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, objectID)
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let identifier = optionalString(value, 0) else {
                throw sqliteError(database)
            }
            return .init(
                identifier: identifier,
                key: key,
                acknowledgedBytes: sqlite3_column_int64(value, 1),
                totalBytes: sqlite3_column_int64(value, 2)
            )
        }
    }

    public static func checkpointUpload(
        objectID: Int64,
        session: ArchiveUploadSession,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            let now = databaseDate(Date())
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database,
                    "UPDATE archive_transfer SET sessionIdentifier=?,transferredBytes=?,totalBytes=?,state='active',updatedAt=? WHERE id=(SELECT id FROM archive_transfer WHERE archiveObjectId=? AND direction='upload' AND state IN ('active','retry_wait') ORDER BY id DESC LIMIT 1)",
                    &statement)
                var value = try unwrap(statement, database)
                bind(session.identifier, to: value, index: 1)
                sqlite3_bind_int64(value, 2, session.acknowledgedBytes)
                sqlite3_bind_int64(value, 3, session.totalBytes)
                bind(now, to: value, index: 4)
                sqlite3_bind_int64(value, 5, objectID)
                try stepDone(value, database)
                sqlite3_finalize(value)
                if sqlite3_changes(database) == 0 {
                    statement = nil
                    try prepare(
                        database,
                        "INSERT INTO archive_transfer(archiveObjectId,direction,state,sessionIdentifier,transferredBytes,totalBytes,createdAt,updatedAt) VALUES(?,'upload','active',?,?,?,?,?)",
                        &statement)
                    value = try unwrap(statement, database)
                    sqlite3_bind_int64(value, 1, objectID)
                    bind(session.identifier, to: value, index: 2)
                    sqlite3_bind_int64(value, 3, session.acknowledgedBytes)
                    sqlite3_bind_int64(value, 4, session.totalBytes)
                    bind(now, to: value, index: 5)
                    bind(now, to: value, index: 6)
                    try stepDone(value, database)
                    sqlite3_finalize(value)
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func discardUploadCheckpoint(
        objectID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            try execute(
                database,
                "DELETE FROM archive_transfer WHERE archiveObjectId=\(objectID) AND direction='upload' AND state IN ('active','retry_wait')"
            )
        }
    }

    public static func recordUploadedObject(
        objectID: Int64,
        metadata: RemoteObjectMetadata,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE archive_object SET remoteIdentifier=?,remoteVersion=?,remoteSHA256=?,remoteState='verifying',lastError=NULL WHERE id=?",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(metadata.identifier, to: value, index: 1)
            bindOptional(metadata.version, to: value, index: 2)
            bindOptional(metadata.sha256, to: value, index: 3)
            sqlite3_bind_int64(value, 4, objectID)
            try stepDone(value, database)
            try execute(
                database,
                "UPDATE archive_transfer SET state='complete',updatedAt='\(databaseDate(Date()))' WHERE archiveObjectId=\(objectID) AND direction='upload' AND state IN ('active','retry_wait')"
            )
        }
    }

    public static func recordVerifiedObject(
        objectID: Int64,
        verification: RemoteVerification,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        guard verification.matches else { throw ArchiveBackendError.verificationMismatch }
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                "UPDATE archive_object SET remoteState='verified',remoteSHA256=?,remoteVersion=?,verifiedAt=?,lastError=NULL WHERE id=? AND remoteState='verifying'",
                &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bindOptional(verification.metadata.sha256, to: value, index: 1)
            bindOptional(verification.metadata.version, to: value, index: 2)
            bind(databaseDate(Date()), to: value, index: 3)
            sqlite3_bind_int64(value, 4, objectID)
            try stepDone(value, database)
            guard sqlite3_changes(database) == 1 else { throw sqliteError(database) }
        }
    }

    public static func recordObjectFailure(
        objectID: Int64,
        error: Error,
        retryable: Bool,
        now: Date = Date(),
        jitterSeconds: TimeInterval? = nil,
        configuration: LibreReverseLibraryConfiguration,
        databaseSession: LibreReverseLibraryWriteSession? = nil
    ) throws {
        try withDatabase(configuration, create: false, session: databaseSession) { database in
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                var statement: OpaquePointer?
                try prepare(
                    database, "UPDATE archive_object SET remoteState=?,lastError=? WHERE id=?",
                    &statement)
                let value = try unwrap(statement, database)
                bind(
                    retryable
                        ? ArchiveRemoteState.retryWait.rawValue
                        : ArchiveRemoteState.failed.rawValue, to: value, index: 1)
                bind(error.localizedDescription, to: value, index: 2)
                sqlite3_bind_int64(value, 3, objectID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                let transferState =
                    retryable
                    ? ArchiveTransferState.retryWait.rawValue
                    : ArchiveTransferState.failed.rawValue
                let previousAttempt = try scalarInt64(
                    database,
                    """
                    SELECT COALESCE(MAX(attempt),0) FROM archive_transfer
                     WHERE archiveObjectId=\(objectID) AND direction='upload'
                    """)
                let attempt = previousAttempt + 1
                let exponent = min(9, max(0, Int(attempt - 1)))
                let jitter = min(0.999, max(0, jitterSeconds ?? Double.random(in: 0..<1)))
                let retryDate =
                    retryable
                    ? databaseDate(
                        now.addingTimeInterval(
                            min(3_600, 5 * pow(2, Double(exponent)) + jitter)
                        ))
                    : nil
                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE archive_transfer
                       SET state=?,attempt=?,retryAfter=?,lastError=?,updatedAt=?
                     WHERE id=(
                       SELECT id FROM archive_transfer
                        WHERE archiveObjectId=? AND direction='upload'
                        ORDER BY id DESC LIMIT 1
                     )
                    """, &statement)
                var transfer = try unwrap(statement, database)
                bind(transferState, to: transfer, index: 1)
                sqlite3_bind_int64(transfer, 2, attempt)
                bindOptional(retryDate, to: transfer, index: 3)
                bind(error.localizedDescription, to: transfer, index: 4)
                bind(databaseDate(now), to: transfer, index: 5)
                sqlite3_bind_int64(transfer, 6, objectID)
                try stepDone(transfer, database)
                sqlite3_finalize(transfer)
                if sqlite3_changes(database) == 0 {
                    statement = nil
                    try prepare(
                        database,
                        """
                        INSERT INTO archive_transfer(
                          archiveObjectId,direction,state,transferredBytes,totalBytes,
                          attempt,retryAfter,lastError,createdAt,updatedAt
                        ) SELECT id,'upload',?,0,byteCount,?,?,?,?,? FROM archive_object WHERE id=?
                        """, &statement)
                    transfer = try unwrap(statement, database)
                    bind(transferState, to: transfer, index: 1)
                    sqlite3_bind_int64(transfer, 2, attempt)
                    bindOptional(retryDate, to: transfer, index: 3)
                    bind(error.localizedDescription, to: transfer, index: 4)
                    bind(databaseDate(now), to: transfer, index: 5)
                    bind(databaseDate(now), to: transfer, index: 6)
                    sqlite3_bind_int64(transfer, 7, objectID)
                    try stepDone(transfer, database)
                    sqlite3_finalize(transfer)
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    public static func nextRetryDate(
        destinationID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession? = nil
    ) throws -> Date? {
        try withDatabase(configuration, create: false, session: session) { database in
            var statement: OpaquePointer?
            try prepare(
                database,
                """
                SELECT MIN(retry.retryAfter)
                  FROM archive_transfer AS retry
                  JOIN archive_object AS object ON object.id=retry.archiveObjectId
                 WHERE object.destinationId=? AND object.remoteState='retry_wait'
                   AND retry.direction='upload' AND retry.state='retry_wait'
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, destinationID)
            guard sqlite3_step(value) == SQLITE_ROW,
                let string = optionalString(value, 0)
            else { return nil }
            return databaseDateFormatter.date(from: string)
        }
    }

    static func enqueueFinalizedVideo(
        videoID: Int64,
        relativePath: String,
        xid: String,
        byteCount: Int64,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            database,
            """
            INSERT OR IGNORE INTO media_residency(videoId,localState,desiredLocal)
            VALUES(?,'present',1)
            """, &statement)
        var value = try unwrap(statement, database)
        sqlite3_bind_int64(value, 1, videoID)
        try stepDone(value, database)
        sqlite3_finalize(value)

        statement = nil
        try prepare(
            database,
            """
            INSERT OR IGNORE INTO archive_object(
              destinationId,videoId,relativePath,objectKey,byteCount,remoteState
            )
            SELECT d.id,?,?,
                   'libraries/' || (SELECT uuid FROM archive_library WHERE id=1) ||
                   '/video/' || printf('%020lld',?) || '/' || ? || '.mp4',?,
                   'queued'
              FROM archive_destination d JOIN archive_policy p ON p.destinationId=d.id
             WHERE d.enabled=1
            """, &statement)
        value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, videoID)
        bind(relativePath, to: value, index: 2)
        sqlite3_bind_int64(value, 3, videoID)
        bind(xid, to: value, index: 4)
        sqlite3_bind_int64(value, 5, byteCount)
        try stepDone(value, database)
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS archive_destination(
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          kind TEXT NOT NULL UNIQUE,displayName TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1,
          remoteRoot TEXT,endpoint TEXT,bucket TEXT,region TEXT,objectPrefix TEXT,
          lastValidatedAt TEXT,lastError TEXT,
          createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS archive_policy(
          destinationId INTEGER PRIMARY KEY NOT NULL REFERENCES archive_destination(id) ON DELETE CASCADE,
          coverageMode TEXT NOT NULL,coverageValue REAL,continuousArchive INTEGER NOT NULL DEFAULT 1,
          requiredLocalSeconds REAL,rehydratedCacheBytes INTEGER NOT NULL DEFAULT 5368709120,
          revision INTEGER NOT NULL DEFAULT 1,updatedAt TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS archive_object(
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          destinationId INTEGER NOT NULL REFERENCES archive_destination(id) ON DELETE CASCADE,
          videoId INTEGER NOT NULL REFERENCES video(id) ON DELETE CASCADE,
          relativePath TEXT NOT NULL,objectKey TEXT NOT NULL,remoteIdentifier TEXT,remoteVersion TEXT,
          byteCount INTEGER NOT NULL,localSHA256 TEXT,remoteSHA256 TEXT,
          remoteState TEXT NOT NULL DEFAULT 'unscheduled',verifiedAt TEXT,lastError TEXT,
          UNIQUE(destinationId,videoId)
        );
        CREATE TABLE IF NOT EXISTS archive_transfer(
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          archiveObjectId INTEGER NOT NULL REFERENCES archive_object(id) ON DELETE CASCADE,
          direction TEXT NOT NULL,state TEXT NOT NULL,sessionIdentifier TEXT,
          transferredBytes INTEGER NOT NULL DEFAULT 0,totalBytes INTEGER NOT NULL,
          attempt INTEGER NOT NULL DEFAULT 0,retryAfter TEXT,leaseOwner TEXT,leaseExpiresAt TEXT,
          priority INTEGER NOT NULL DEFAULT 0,lastError TEXT,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS media_residency(
          videoId INTEGER PRIMARY KEY NOT NULL REFERENCES video(id) ON DELETE CASCADE,
          localState TEXT NOT NULL DEFAULT 'present',desiredLocal INTEGER NOT NULL DEFAULT 1,
          activeLeases INTEGER NOT NULL DEFAULT 0,lastAccessAt TEXT,localVerifiedAt TEXT,
          stagingPath TEXT,lastError TEXT,
          isCache INTEGER NOT NULL DEFAULT 0,cacheRetainUntil TEXT
        );
        CREATE TABLE IF NOT EXISTS archive_library(
          id INTEGER PRIMARY KEY CHECK(id=1),uuid TEXT NOT NULL UNIQUE
        );
        INSERT OR IGNORE INTO archive_library(id,uuid) VALUES(1,lower(hex(randomblob(16))));
        CREATE TABLE IF NOT EXISTS archive_credential(
          account TEXT PRIMARY KEY NOT NULL,value BLOB NOT NULL,
          createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL
        );
        -- Recovery journals intentionally outlive their deleted canonical graph.
        CREATE TABLE IF NOT EXISTS meeting_deletion(
          segmentId INTEGER PRIMARY KEY NOT NULL,planJSON BLOB NOT NULL,
          state TEXT NOT NULL,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL,
          lastError TEXT,shardId INTEGER
        );
        CREATE INDEX IF NOT EXISTS index_meeting_deletion_on_shard ON meeting_deletion(shardId,state);
        CREATE TABLE IF NOT EXISTS meeting_title_update(
          segmentId INTEGER PRIMARY KEY NOT NULL,shardId INTEGER,planJSON BLOB NOT NULL,
          state TEXT NOT NULL,createdAt TEXT NOT NULL,updatedAt TEXT NOT NULL,lastError TEXT
        );
        CREATE INDEX IF NOT EXISTS index_meeting_title_update_on_shard ON meeting_title_update(shardId,state);
        CREATE INDEX IF NOT EXISTS archive_object_state_video ON archive_object(destinationId,remoteState,videoId);
        CREATE INDEX IF NOT EXISTS archive_transfer_state_priority ON archive_transfer(state,priority DESC,id);
        """

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
            throw LibreReverseArchiveStoreError.unableToOpenDatabase(message)
        }
        defer { sqlite3_close(database) }
        let keyStatus = key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }
        guard keyStatus == SQLITE_OK else {
            throw LibreReverseArchiveStoreError.unableToApplyKey(keyStatus)
        }
        try execute(
            database, "PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON")
        return try operation(database)
    }

    private static func prepare(
        _ database: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?
    ) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }
    private static func unwrap(_ statement: OpaquePointer?, _ database: OpaquePointer) throws
        -> OpaquePointer
    {
        guard let statement else { throw sqliteError(database) }
        return statement
    }
    private static func stepDone(_ statement: OpaquePointer, _ database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }
    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(message)
            throw LibreReverseArchiveStoreError.sqlite(text)
        }
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
            statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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
    private static func bindOptional(_ value: Double?, to statement: OpaquePointer, index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    private static func bindOptional(_ value: String?, to statement: OpaquePointer, index: Int32) {
        if let value {
            bind(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    private static func decodeObject(_ value: OpaquePointer) throws -> LibreReverseArchiveObject {
        .init(
            id: sqlite3_column_int64(value, 0),
            destinationID: sqlite3_column_int64(value, 1),
            videoID: sqlite3_column_int64(value, 2),
            relativePath: string(value, 3),
            objectKey: string(value, 4),
            byteCount: sqlite3_column_int64(value, 5),
            localSHA256: optionalString(value, 6),
            remoteIdentifier: optionalString(value, 7),
            remoteState: try ArchiveRemoteState.decodePersisted(string(value, 8))
        )
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }
    private static func optionalString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column)
    }
    private static func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, column)
    }
    private static func databaseDate(_ date: Date) -> String {
        databaseDateFormatter.string(from: date)
    }
    private static let databaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()
    private static func sqliteError(_ database: OpaquePointer) -> LibreReverseArchiveStoreError {
        .sqlite(errorMessage(database))
    }
    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}
#endif
