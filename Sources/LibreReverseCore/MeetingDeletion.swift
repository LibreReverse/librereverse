#if os(macOS)
import CSQLCipher
import Foundation

public struct LibreReverseMeetingDeletionRemoteObject: Codable, Equatable, Sendable {
    public let archiveObjectID: Int64
    public let destinationID: Int64
    public let previousState: ArchiveRemoteState
    public let metadata: RemoteObjectMetadata?
    public let key: ArchiveObjectKey
}

public struct LibreReverseMeetingDeletionPlan: Codable, Equatable, Sendable {
    public enum Ownership: String, Codable, Sendable {
        case primary
        case sealedShard = "sealed_shard"
        case remoteShard = "remote_shard"
    }

    public let segmentID: Int64
    public let videoID: Int64
    public let xid: String
    public let relativeMediaPath: String
    public let startDate: Date
    public let ownership: Ownership
    public let shardID: Int64?
    public let shardOrdinal: Int64?
    public let shardRelativePath: String?
    public let shardPriorSHA256: String?
    public let shardReplacementSHA256: String?
    public let shardReplacementByteCount: Int64?
    public let remoteObjects: [LibreReverseMeetingDeletionRemoteObject]
}

public enum LibreReverseMeetingDeletionError: Error, LocalizedError, Equatable {
    case meetingNotFound(Int64)
    case malformedMeeting(String)
    case sealedShardRequiresRewrite(Int64)
    case remoteShardRequiresRestore(Int64)
    case shardArchiveBusy(Int64)
    case shardMutationBusy(Int64)
    case unsupportedArchiveDestination(Int64)
    case archiveProviderRequired
    case unsafeMediaPath(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) no longer exists."
        case .malformedMeeting(let message): message
        case .sealedShardRequiresRewrite(let id):
            "Meeting \(id) belongs to a sealed database shard and requires copy-on-write deletion."
        case .remoteShardRequiresRestore(let id):
            "Meeting \(id) belongs to an archived database shard that must be restored before deletion."
        case .shardArchiveBusy(let id):
            "Meeting \(id) is in a database shard with an active archive transfer. Try again after it finishes."
        case .shardMutationBusy(let id):
            "Meeting \(id) is in a database shard with another meeting change in progress. Try again after it finishes."
        case .unsupportedArchiveDestination(let id):
            "Meeting deletion was not given the archive provider for destination \(id)."
        case .archiveProviderRequired:
            "Connect the meeting’s archive provider before deleting its archived media."
        case .unsafeMediaPath(let path): "Refusing unsafe meeting media path: \(path)"
        case .database(let message): "Meeting deletion database error: \(message)"
        }
    }
}

public protocol LibreReverseMeetingShardRestoring: Sendable {
    func restoreForMeetingDeletion(ordinal: Int64) async throws -> URL
}

/// Provider-neutral end-to-end deletion. It first guarantees a recoverable
/// local media copy, removes video objects from the configured archive, commits
/// the primary or COW shard graph, and only then removes local media. A remote
/// failure restores the journaled graph and requeues any uncertain object.
public struct LibreReverseMeetingDeletionCoordinator: Sendable {
    private let destinationID: Int64?
    private let library: LibreReverseLibraryConfiguration
    private let backend: (any ArchiveBackend)?
    private let shardRestorer: (any LibreReverseMeetingShardRestoring)?
    private let transcriptionQueue: LibreReverseMeetingTranscriptionQueue?

    public init(
        destinationID: Int64? = nil,
        library: LibreReverseLibraryConfiguration,
        backend: (any ArchiveBackend)? = nil,
        shardRestorer: (any LibreReverseMeetingShardRestoring)? = nil,
        transcriptionQueue: LibreReverseMeetingTranscriptionQueue? = nil
    ) {
        self.destinationID = destinationID
        self.library = library
        self.backend = backend
        self.shardRestorer = shardRestorer
        self.transcriptionQueue = transcriptionQueue
    }

    /// Replays user-authorized deletions left by process interruption. Remote
    /// removal is idempotent, and a `database_deleted` journal advances only
    /// through local cleanup. Provider failures preserve the intact graph.
    @discardableResult
    public func resumePendingDeletions() async throws -> Int {
        let plans = try LibreReverseMeetingDeletion.pendingPlans(
            configuration: library
        )
        var completed = 0
        for plan in plans {
            try Task.checkCancellation()
            if !plan.remoteObjects.isEmpty {
                guard let destinationID, backend != nil,
                    plan.remoteObjects.allSatisfy({
                        $0.destinationID == destinationID
                    })
                else { continue }
            }
            try await delete(segmentID: plan.segmentID, abortOnFailure: false)
            completed += 1
        }
        return completed
    }

    public func delete(segmentID: Int64) async throws {
        try await delete(segmentID: segmentID, abortOnFailure: true)
    }

    private func delete(
        segmentID: Int64,
        abortOnFailure: Bool
    ) async throws {
        let initialPlan: LibreReverseMeetingDeletionPlan
        do {
            initialPlan = try LibreReverseMeetingDeletion.prepare(
                segmentID: segmentID,
                configuration: library
            )
        } catch LibreReverseMeetingDeletionError.remoteShardRequiresRestore {
            guard let shardRestorer,
                let ordinal =
                    try LibreReverseMeetingDeletion
                    .remoteShardOrdinalRequiringRestore(
                        segmentID: segmentID,
                        configuration: library
                    )
            else {
                throw LibreReverseMeetingDeletionError.remoteShardRequiresRestore(segmentID)
            }
            _ = try await shardRestorer.restoreForMeetingDeletion(ordinal: ordinal)
            initialPlan = try LibreReverseMeetingDeletion.prepare(
                segmentID: segmentID,
                configuration: library
            )
        }
        var plan = initialPlan
        if !plan.remoteObjects.isEmpty,
            destinationID == nil || backend == nil
        {
            try LibreReverseMeetingDeletion.abortPreparedDeletion(
                plan,
                requeueRemote: false,
                configuration: library
            )
            throw LibreReverseMeetingDeletionError.archiveProviderRequired
        }
        guard
            plan.remoteObjects.allSatisfy({
                $0.destinationID == destinationID
            })
        else {
            try LibreReverseMeetingDeletion.abortPreparedDeletion(
                plan,
                requeueRemote: false,
                configuration: library
            )
            let unsupported =
                plan.remoteObjects.first {
                    $0.destinationID != destinationID
                }?.destinationID ?? destinationID ?? -1
            throw LibreReverseMeetingDeletionError.unsupportedArchiveDestination(unsupported)
        }
        var attemptedRemoteRemoval = false
        var databaseCommitted = false
        do {
            let localURL = library.mediaRoot.appendingPathComponent(
                plan.relativeMediaPath
            )
            if !FileManager.default.fileExists(atPath: localURL.path) {
                // `prepare` freezes the archive row, while the resolver reads
                // only verified rows. Briefly release the journal to restore
                // the recoverable local copy, then acquire a fresh plan.
                try LibreReverseMeetingDeletion.abortPreparedDeletion(
                    plan,
                    requeueRemote: false,
                    configuration: library
                )
                guard let destinationID, let backend else {
                    throw LibreReverseMeetingDeletionError.archiveProviderRequired
                }
                let resolver = LibreReverseLocalMediaResolver(
                    destinationID: destinationID,
                    library: library,
                    backend: backend
                )
                _ = try await resolver.resolve(videoID: plan.videoID)
                plan = try LibreReverseMeetingDeletion.prepare(
                    segmentID: segmentID,
                    configuration: library
                )
            }
            let backend = self.backend
            for object in plan.remoteObjects {
                try Task.checkCancellation()
                let metadata: RemoteObjectMetadata?
                if let recorded = object.metadata {
                    metadata = recorded
                } else {
                    guard let backend else {
                        throw LibreReverseMeetingDeletionError.archiveProviderRequired
                    }
                    metadata = try await backend.locate(object.key)
                }
                if let metadata {
                    guard let backend else {
                        throw LibreReverseMeetingDeletionError.archiveProviderRequired
                    }
                    attemptedRemoteRemoval = true
                    try await backend.remove(metadata)
                }
            }
            switch plan.ownership {
            case .primary:
                try LibreReverseMeetingDeletion.commitPreparedPrimaryDeletion(
                    plan,
                    configuration: library
                )
            case .sealedShard:
                try LibreReverseMeetingDeletion.commitPreparedSealedShardDeletion(
                    plan,
                    configuration: library
                )
            case .remoteShard:
                throw LibreReverseMeetingDeletionError.remoteShardRequiresRestore(segmentID)
            }
            databaseCommitted = true
            if let transcriptionQueue {
                try transcriptionQueue.removeDeletedPublication(
                    publicationXID: plan.xid,
                    relativeMediaPath: plan.relativeMediaPath
                )
            }
            let committedPlan =
                try LibreReverseMeetingDeletion.pendingPlans(
                    configuration: library
                ).first(where: { $0.segmentID == segmentID }) ?? plan
            try LibreReverseMeetingDeletion.finishPreparedDeletion(
                committedPlan,
                configuration: library
            )
        } catch {
            if !databaseCommitted, abortOnFailure {
                try? LibreReverseMeetingDeletion.abortPreparedDeletion(
                    plan,
                    requeueRemote: attemptedRemoteRemoval,
                    configuration: library
                )
            }
            throw error
        }
    }
}

/// Crash-recoverable deletion protocol for primary- and sealed-shard meetings.
///
/// `prepare` durably journals the complete plan and moves archive objects into
/// a non-uploadable state. The caller removes each remote object (or confirms
/// it is absent), then calls `commitPreparedPrimaryDeletion`. A failure after
/// remote removal must call `abortPreparedDeletion(requeueRemote: true)` so the
/// still-intact local graph is uploaded again. A sealed shard is rewritten to a
/// verified temporary copy and atomically replaced. Its former remote object is
/// retained until the content-addressed replacement has itself been verified.
public enum LibreReverseMeetingDeletion {
    public static func remoteShardOrdinalRequiringRestore(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Int64? {
        let start = try withDatabase(configuration) { database -> Date in
            var statement: OpaquePointer?
            try prepare(
                database,
                "SELECT startDate FROM segment WHERE id=? AND type=1",
                &statement
            )
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            sqlite3_bind_int64(value, 1, segmentID)
            guard sqlite3_step(value) == SQLITE_ROW,
                let raw = optionalString(value, column: 0),
                let start = databaseDate(raw)
            else {
                throw LibreReverseMeetingDeletionError.meetingNotFound(segmentID)
            }
            return start
        }
        return try LibreReverseShardStore.records(configuration: configuration)
            .filter { $0.interval.contains(start) && $0.state == .remoteOnly }
            .max(by: { $0.generation < $1.generation })?
            .interval.ordinal
    }

    public static func prepare(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> LibreReverseMeetingDeletionPlan {
        try withDatabase(configuration) { database in
            if let pending = try pendingPlan(segmentID: segmentID, database: database) {
                return pending
            }
            let plan = try loadPlan(
                segmentID: segmentID,
                configuration: configuration,
                database: database
            )
            if plan.ownership == .remoteShard {
                throw LibreReverseMeetingDeletionError.remoteShardRequiresRestore(segmentID)
            }
            if let shardID = plan.shardID,
                try scalar(
                    database,
                    """
                    SELECT COUNT(*) FROM shard_archive_object
                     WHERE shardId=\(shardID)
                       AND remoteState IN ('hashing','uploading','verifying')
                    """) > 0
            {
                throw LibreReverseMeetingDeletionError.shardArchiveBusy(segmentID)
            }
            let encoded = try JSONEncoder().encode(plan)
            try execute(database, "BEGIN IMMEDIATE")
            do {
                // Both mutation types rewrite the whole shard. Admit only one
                // unresolved plan so its prior hash remains valid for recovery.
                if let shardID = plan.shardID,
                    try scalar(
                        database,
                        """
                        SELECT
                          (SELECT COUNT(*) FROM meeting_title_update
                            WHERE shardId=\(shardID)
                              AND state IN ('prepared','replacement_ready'))
                          + (SELECT COUNT(*) FROM meeting_deletion
                            WHERE shardId=\(shardID)
                              AND state IN ('prepared','replacement_ready'))
                        """
                    ) > 0
                {
                    throw LibreReverseMeetingDeletionError.shardMutationBusy(segmentID)
                }
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    INSERT INTO meeting_deletion(
                      segmentId,shardId,planJSON,state,createdAt,updatedAt,lastError
                    ) VALUES(?,?,?,'prepared',?,?,NULL)
                    """, &statement)
                var value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, segmentID)
                bindOptional(plan.shardID, to: value, index: 2)
                bind(encoded, to: value, index: 3)
                bind(dateString(Date()), to: value, index: 4)
                bind(dateString(Date()), to: value, index: 5)
                try stepDone(value, database)
                sqlite3_finalize(value)
                statement = nil
                try prepare(
                    database,
                    """
                    UPDATE archive_object SET remoteState='deleting'
                     WHERE videoId=?
                    """, &statement)
                value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, plan.videoID)
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
    ) throws -> [LibreReverseMeetingDeletionPlan] {
        try withDatabase(configuration) { database in
            var statement: OpaquePointer?
            try prepare(
                database, "SELECT planJSON FROM meeting_deletion ORDER BY createdAt", &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            var plans: [LibreReverseMeetingDeletionPlan] = []
            while sqlite3_step(value) == SQLITE_ROW {
                plans.append(
                    try JSONDecoder().decode(
                        LibreReverseMeetingDeletionPlan.self,
                        from: data(value, column: 0)
                    ))
            }
            return plans
        }
    }

    public static func commitPreparedPrimaryDeletion(
        _ plan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard plan.ownership == .primary else {
            throw LibreReverseMeetingDeletionError.sealedShardRequiresRewrite(plan.segmentID)
        }
        try withDatabase(configuration) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                guard try pendingPlan(segmentID: plan.segmentID, database: database) == plan else {
                    throw LibreReverseMeetingDeletionError.database("deletion journal changed")
                }
                let id = plan.segmentID
                let video = plan.videoID
                try execute(
                    database,
                    """
                    DELETE FROM summary WHERE eventId IN (
                      SELECT id FROM event WHERE segmentID=\(id)
                    );
                    DELETE FROM event WHERE segmentID=\(id);
                    DELETE FROM node WHERE frameId IN (
                      SELECT id FROM frame WHERE segmentId=\(id)
                    );
                    DELETE FROM frame_processing WHERE id IN (
                      SELECT id FROM frame WHERE segmentId=\(id)
                    );
                    DELETE FROM capture_journal WHERE frameId IN (
                      SELECT id FROM frame WHERE segmentId=\(id)
                    );
                    """)
                let documentIDs = try int64s(
                    database,
                    """
                    SELECT docid FROM doc_segment WHERE segmentId=\(id)
                    """)
                try execute(database, "DELETE FROM doc_segment WHERE segmentId=\(id)")
                for documentID in documentIDs {
                    try execute(database, "DELETE FROM searchRanking WHERE rowid=\(documentID)")
                    try execute(database, "DELETE FROM search WHERE rowid=\(documentID)")
                    try execute(database, "DELETE FROM searchOffsets WHERE rowid=\(documentID)")
                }
                try execute(
                    database,
                    """
                    DELETE FROM transcript_word WHERE segmentId=\(id);
                    DELETE FROM audio WHERE segmentId=\(id);
                    DELETE FROM frame WHERE segmentId=\(id);
                    DELETE FROM archive_transfer WHERE archiveObjectId IN (
                      SELECT id FROM archive_object WHERE videoId=\(video)
                    );
                    DELETE FROM archive_object WHERE videoId=\(video);
                    DELETE FROM media_residency WHERE videoId=\(video);
                    DELETE FROM video WHERE id=\(video)
                      AND NOT EXISTS(SELECT 1 FROM frame WHERE videoId=\(video));
                    DELETE FROM segment WHERE id=\(id) AND type=1;
                    UPDATE meeting_deletion SET state='database_deleted',updatedAt='\(sql(dateString(Date())))'
                     WHERE segmentId=\(id);
                    """)
                guard try scalar(database, "SELECT COUNT(*) FROM segment WHERE id=\(id)") == 0,
                    try scalar(database, "SELECT COUNT(*) FROM video WHERE id=\(video)") == 0
                else {
                    throw LibreReverseMeetingDeletionError.database(
                        "meeting graph retained shared or unexpected rows"
                    )
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    /// Rewrites an immutable local shard through a verified temporary file,
    /// atomically installs it, and advances the primary catalog. Repeating the
    /// call after an interruption resumes from the journaled replacement hash.
    public static func commitPreparedSealedShardDeletion(
        _ requestedPlan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration,
        fileManager: FileManager = .default
    ) throws {
        guard requestedPlan.ownership == .sealedShard else {
            throw LibreReverseMeetingDeletionError.sealedShardRequiresRewrite(
                requestedPlan.segmentID
            )
        }
        var plan = try withDatabase(configuration) { database in
            if try deletionState(
                segmentID: requestedPlan.segmentID,
                database: database
            ) == "database_deleted" {
                return try pendingPlan(
                    segmentID: requestedPlan.segmentID,
                    database: database
                ) ?? requestedPlan
            }
            guard
                let value = try pendingPlan(
                    segmentID: requestedPlan.segmentID,
                    database: database
                )
            else {
                throw LibreReverseMeetingDeletionError.database("deletion journal is missing")
            }
            return value
        }
        if try withDatabase(
            configuration,
            operation: { database in
                try deletionState(segmentID: plan.segmentID, database: database)
            }) == "database_deleted"
        {
            return
        }
        let locations = try shardRewriteLocations(plan, configuration: configuration)
        if plan.shardReplacementSHA256 == nil {
            if fileManager.fileExists(atPath: locations.temporary.path) {
                try fileManager.removeItem(at: locations.temporary)
            }
            try fileManager.copyItem(at: locations.canonical, to: locations.temporary)
            try rewriteShard(
                at: locations.temporary,
                plan: plan,
                keyFileURL: configuration.keyFileURL
            )
            let integrity = try ArchiveIntegrityEngine.hash(file: locations.temporary)
            plan = replacementPlan(
                plan,
                integrity: integrity
            )
            let encoded = try JSONEncoder().encode(plan)
            try withDatabase(configuration) { database in
                try execute(database, "BEGIN IMMEDIATE")
                do {
                    guard
                        try pendingPlan(
                            segmentID: plan.segmentID,
                            database: database
                        )?.shardReplacementSHA256 == nil
                    else {
                        throw LibreReverseMeetingDeletionError.database(
                            "shard replacement was prepared concurrently"
                        )
                    }
                    var statement: OpaquePointer?
                    try prepare(
                        database,
                        """
                        UPDATE meeting_deletion
                           SET planJSON=?,state='replacement_ready',updatedAt=?
                         WHERE segmentId=?
                        """, &statement)
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
        try ensureReplacementFile(
            plan: plan,
            locations: locations,
            keyFileURL: configuration.keyFileURL,
            fileManager: fileManager
        )
        try installReplacementIfNeeded(
            plan: plan,
            locations: locations,
            fileManager: fileManager
        )
        try finalizeShardReplacement(plan, configuration: configuration)
    }

    public static func finishPreparedDeletion(
        _ plan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration,
        fileManager: FileManager = .default
    ) throws {
        let state = try withDatabase(configuration) { database in
            try deletionState(segmentID: plan.segmentID, database: database)
        }
        guard state == "database_deleted" else {
            throw LibreReverseMeetingDeletionError.database(
                "meeting media cannot be removed before its database graph commits"
            )
        }
        let mediaURL = try safeMediaURL(plan, configuration: configuration)
        if fileManager.fileExists(atPath: mediaURL.path) {
            try fileManager.removeItem(at: mediaURL)
        }
        if plan.ownership == .sealedShard,
            let locations = try? shardRewriteLocations(plan, configuration: configuration)
        {
            for url in [locations.temporary, locations.backup]
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        try withDatabase(configuration) { database in
            try execute(
                database,
                "DELETE FROM meeting_deletion WHERE segmentId=\(plan.segmentID) AND state='database_deleted'"
            )
        }
    }

    public static func abortPreparedDeletion(
        _ plan: LibreReverseMeetingDeletionPlan,
        requeueRemote: Bool,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        let journalPlan = try withDatabase(configuration) { database in
            if try deletionState(segmentID: plan.segmentID, database: database)
                == "database_deleted"
            {
                throw LibreReverseMeetingDeletionError.database(
                    "a committed meeting deletion cannot be aborted"
                )
            }
            return try pendingPlan(segmentID: plan.segmentID, database: database)
        }
        guard let journalPlan else { return }
        if journalPlan.ownership == .sealedShard,
            journalPlan.shardReplacementSHA256 != nil
        {
            let locations = try shardRewriteLocations(
                journalPlan,
                configuration: configuration
            )
            let current = try ArchiveIntegrityEngine.hash(file: locations.canonical)
            if current.sha256 == journalPlan.shardReplacementSHA256 {
                guard FileManager.default.fileExists(atPath: locations.backup.path) else {
                    throw LibreReverseMeetingDeletionError.database(
                        "cannot abort an installed shard replacement without its backup"
                    )
                }
                _ = try FileManager.default.replaceItemAt(
                    locations.canonical,
                    withItemAt: locations.backup
                )
            }
            if FileManager.default.fileExists(atPath: locations.temporary.path) {
                try FileManager.default.removeItem(at: locations.temporary)
            }
        }
        try withDatabase(configuration) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                for object in plan.remoteObjects {
                    let state = requeueRemote ? ArchiveRemoteState.queued : object.previousState
                    if requeueRemote {
                        try execute(
                            database,
                            "DELETE FROM archive_transfer WHERE archiveObjectId=\(object.archiveObjectID) AND state!='complete'"
                        )
                    }
                    try execute(
                        database,
                        "UPDATE archive_object SET remoteState='\(state.rawValue)',remoteIdentifier=\(requeueRemote ? "NULL" : "remoteIdentifier"),remoteVersion=\(requeueRemote ? "NULL" : "remoteVersion"),remoteSHA256=\(requeueRemote ? "NULL" : "remoteSHA256"),verifiedAt=\(requeueRemote ? "NULL" : "verifiedAt"),lastError=NULL WHERE id=\(object.archiveObjectID)"
                    )
                }
                try execute(
                    database, "DELETE FROM meeting_deletion WHERE segmentId=\(plan.segmentID)")
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private static func loadPlan(
        segmentID: Int64,
        configuration: LibreReverseLibraryConfiguration,
        database: OpaquePointer
    ) throws -> LibreReverseMeetingDeletionPlan {
        var statement: OpaquePointer?
        try prepare(
            database,
            """
            SELECT startDate FROM segment WHERE id=? AND type=1
            """, &statement)
        var value = try unwrap(statement, database)
        sqlite3_bind_int64(value, 1, segmentID)
        guard sqlite3_step(value) == SQLITE_ROW else {
            sqlite3_finalize(value)
            throw LibreReverseMeetingDeletionError.meetingNotFound(segmentID)
        }
        guard let startRaw = optionalString(value, column: 0),
            let start = databaseDate(startRaw)
        else {
            sqlite3_finalize(value)
            throw LibreReverseMeetingDeletionError.malformedMeeting(
                "Meeting has incomplete media identity.")
        }
        sqlite3_finalize(value)
        let primaryIdentity = try videoIdentity(
            segmentID: segmentID,
            database: database
        )
        let ownership: LibreReverseMeetingDeletionPlan.Ownership
        let shardID: Int64?
        let shardOrdinal: Int64?
        let shardRelativePath: String?
        let shardPriorSHA256: String?
        let identity: (videoID: Int64, xid: String, path: String)
        if let primaryIdentity {
            ownership = .primary
            shardID = nil
            shardOrdinal = nil
            shardRelativePath = nil
            shardPriorSHA256 = nil
            identity = primaryIdentity
        } else {
            guard
                let shard = try LibreReverseShardStore.records(
                    configuration: configuration
                ).filter({ $0.interval.contains(start) }).max(by: {
                    $0.generation < $1.generation
                })
            else {
                throw LibreReverseMeetingDeletionError.malformedMeeting(
                    "Meeting payload is absent from both the primary library and shard catalog."
                )
            }
            shardID = shard.id
            shardOrdinal = shard.interval.ordinal
            guard shard.state == .sealedLocal else {
                throw LibreReverseMeetingDeletionError.remoteShardRequiresRestore(segmentID)
            }
            guard let relativePath = shard.relativePath else {
                throw LibreReverseMeetingDeletionError.malformedMeeting(
                    "Meeting shard has no local path."
                )
            }
            guard let priorSHA256 = shard.sha256 else {
                throw LibreReverseMeetingDeletionError.malformedMeeting(
                    "Meeting shard has no verified content hash."
                )
            }
            shardRelativePath = relativePath
            shardPriorSHA256 = priorSHA256
            let shardURL = try safeShardURL(
                relativePath,
                configuration: configuration
            )
            identity = try withKeyedDatabase(
                url: shardURL,
                keyFileURL: configuration.keyFileURL
            ) { shardDatabase in
                guard
                    let identity = try videoIdentity(
                        segmentID: segmentID,
                        database: shardDatabase
                    )
                else {
                    throw LibreReverseMeetingDeletionError.malformedMeeting(
                        "Meeting payload is missing from its sealed shard."
                    )
                }
                return identity
            }
            ownership = .sealedShard
        }
        let videoID = identity.videoID
        let xid = identity.xid
        let path = identity.path
        guard VideoStorage.isCanonicalRelativePath(path, xid: xid) else {
            throw LibreReverseMeetingDeletionError.unsafeMediaPath(path)
        }
        try prepare(
            database,
            """
            SELECT id,destinationId,objectKey,remoteIdentifier,remoteVersion,
                   byteCount,remoteSHA256,remoteState
              FROM archive_object WHERE videoId=? ORDER BY id
            """, &statement)
        value = try unwrap(statement, database)
        sqlite3_bind_int64(value, 1, videoID)
        var remotes: [LibreReverseMeetingDeletionRemoteObject] = []
        while sqlite3_step(value) == SQLITE_ROW {
            let key = ArchiveObjectKey(string(value, column: 2))
            let identifier = optionalString(value, column: 3)
            let metadata = identifier.map {
                RemoteObjectMetadata(
                    identifier: $0,
                    version: optionalString(value, column: 4),
                    key: key,
                    byteCount: sqlite3_column_int64(value, 5),
                    sha256: optionalString(value, column: 6)
                )
            }
            remotes.append(
                .init(
                    archiveObjectID: sqlite3_column_int64(value, 0),
                    destinationID: sqlite3_column_int64(value, 1),
                    previousState: try ArchiveRemoteState.decodePersisted(string(value, column: 7)),
                    metadata: metadata,
                    key: key
                ))
        }
        sqlite3_finalize(value)
        return .init(
            segmentID: segmentID,
            videoID: videoID,
            xid: xid,
            relativeMediaPath: path,
            startDate: start,
            ownership: ownership,
            shardID: shardID,
            shardOrdinal: shardOrdinal,
            shardRelativePath: shardRelativePath,
            shardPriorSHA256: shardPriorSHA256,
            shardReplacementSHA256: nil,
            shardReplacementByteCount: nil,
            remoteObjects: remotes
        )
    }

    private static func videoIdentity(
        segmentID: Int64,
        database: OpaquePointer
    ) throws -> (videoID: Int64, xid: String, path: String)? {
        var statement: OpaquePointer?
        try prepare(
            database,
            """
            SELECT DISTINCT v.id,v.xid,v.path
              FROM frame f JOIN video v ON v.id=f.videoId
             WHERE f.segmentId=?
            """, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, segmentID)
        guard sqlite3_step(value) == SQLITE_ROW,
            let xid = optionalString(value, column: 1),
            let path = optionalString(value, column: 2)
        else { return nil }
        let result = (sqlite3_column_int64(value, 0), xid, path)
        guard sqlite3_step(value) == SQLITE_DONE else {
            throw LibreReverseMeetingDeletionError.malformedMeeting(
                "Meeting references more than one video object."
            )
        }
        return result
    }

    private struct ShardPayloadCounts {
        let frames: Int64
        let nodes: Int64
        let documents: Int64
        let minFrameID: Int64?
        let maxFrameID: Int64?
        let calendarHours: [(hour: String, sample: String)]
    }

    private struct ShardRewriteLocations {
        let canonical: URL
        let temporary: URL
        let backup: URL
    }

    private static func replacementPlan(
        _ plan: LibreReverseMeetingDeletionPlan,
        integrity: ArchiveIntegrity
    ) -> LibreReverseMeetingDeletionPlan {
        .init(
            segmentID: plan.segmentID,
            videoID: plan.videoID,
            xid: plan.xid,
            relativeMediaPath: plan.relativeMediaPath,
            startDate: plan.startDate,
            ownership: plan.ownership,
            shardID: plan.shardID,
            shardOrdinal: plan.shardOrdinal,
            shardRelativePath: plan.shardRelativePath,
            shardPriorSHA256: plan.shardPriorSHA256,
            shardReplacementSHA256: integrity.sha256,
            shardReplacementByteCount: integrity.byteCount,
            remoteObjects: plan.remoteObjects
        )
    }

    private static func shardRewriteLocations(
        _ plan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> ShardRewriteLocations {
        guard let relativePath = plan.shardRelativePath else {
            throw LibreReverseMeetingDeletionError.malformedMeeting(
                "Meeting deletion plan has no shard path."
            )
        }
        let canonical = try safeShardURL(relativePath, configuration: configuration)
        let suffix = "meeting-delete-\(plan.segmentID)"
        return .init(
            canonical: canonical,
            temporary: canonical.deletingLastPathComponent()
                .appendingPathComponent(".\(canonical.lastPathComponent).\(suffix).tmp"),
            backup: canonical.deletingLastPathComponent()
                .appendingPathComponent(".\(canonical.lastPathComponent).\(suffix).backup")
        )
    }

    private static func ensureReplacementFile(
        plan: LibreReverseMeetingDeletionPlan,
        locations: ShardRewriteLocations,
        keyFileURL: URL,
        fileManager: FileManager
    ) throws {
        guard let replacementSHA = plan.shardReplacementSHA256,
            let priorSHA = plan.shardPriorSHA256
        else {
            throw LibreReverseMeetingDeletionError.database(
                "shard replacement hash is not journaled"
            )
        }
        let current = try ArchiveIntegrityEngine.hash(file: locations.canonical)
        if current.sha256 == replacementSHA { return }
        guard current.sha256 == priorSHA else {
            throw LibreReverseMeetingDeletionError.database(
                "meeting shard changed outside its deletion journal"
            )
        }
        if fileManager.fileExists(atPath: locations.temporary.path),
            try ArchiveIntegrityEngine.hash(file: locations.temporary).sha256 == replacementSHA
        {
            return
        }
        if fileManager.fileExists(atPath: locations.temporary.path) {
            try fileManager.removeItem(at: locations.temporary)
        }
        try fileManager.copyItem(at: locations.canonical, to: locations.temporary)
        try rewriteShard(at: locations.temporary, plan: plan, keyFileURL: keyFileURL)
        guard try ArchiveIntegrityEngine.hash(file: locations.temporary).sha256 == replacementSHA
        else {
            throw LibreReverseMeetingDeletionError.database(
                "recreated shard replacement has a different content hash"
            )
        }
    }

    private static func installReplacementIfNeeded(
        plan: LibreReverseMeetingDeletionPlan,
        locations: ShardRewriteLocations,
        fileManager: FileManager
    ) throws {
        guard let replacementSHA = plan.shardReplacementSHA256,
            let priorSHA = plan.shardPriorSHA256
        else {
            throw LibreReverseMeetingDeletionError.database("invalid shard replacement plan")
        }
        let current = try ArchiveIntegrityEngine.hash(file: locations.canonical)
        if current.sha256 == replacementSHA { return }
        guard current.sha256 == priorSHA,
            try ArchiveIntegrityEngine.hash(file: locations.temporary).sha256 == replacementSHA
        else {
            throw LibreReverseMeetingDeletionError.database(
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
            throw LibreReverseMeetingDeletionError.database(
                "installed shard replacement failed its content-hash check"
            )
        }
    }

    private static func rewriteShard(
        at url: URL,
        plan: LibreReverseMeetingDeletionPlan,
        keyFileURL: URL
    ) throws {
        try withWritableKeyedDatabase(url: url, keyFileURL: keyFileURL) { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                try deleteMeetingPayload(
                    database,
                    segmentID: plan.segmentID,
                    videoID: plan.videoID,
                    deleteDimensions: true
                )
                guard
                    try scalar(database, "SELECT COUNT(*) FROM segment WHERE id=\(plan.segmentID)")
                        == 0,
                    try scalar(database, "SELECT COUNT(*) FROM video WHERE id=\(plan.videoID)")
                        == 0,
                    try scalar(database, "SELECT COUNT(*) FROM pragma_foreign_key_check") == 0
                else {
                    throw LibreReverseMeetingDeletionError.database(
                        "rewritten shard retained meeting rows or dangling relationships"
                    )
                }
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
                throw LibreReverseMeetingDeletionError.database(
                    "rewritten shard failed SQLCipher integrity: \(string(value, column: 0))"
                )
            }
        }
    }

    private static func deleteMeetingPayload(
        _ database: OpaquePointer,
        segmentID: Int64,
        videoID: Int64,
        deleteDimensions: Bool
    ) throws {
        let documentIDs = try int64s(
            database,
            "SELECT docid FROM doc_segment WHERE segmentId=\(segmentID)"
        )
        try execute(
            database,
            """
            DELETE FROM node WHERE frameId IN (
              SELECT id FROM frame WHERE segmentId=\(segmentID)
            );
            DELETE FROM doc_segment WHERE segmentId=\(segmentID);
            """)
        if try tableExists("frame_processing", database: database) {
            try execute(
                database,
                """
                DELETE FROM frame_processing WHERE id IN (
                  SELECT id FROM frame WHERE segmentId=\(segmentID)
                )
                """)
        }
        if try tableExists("capture_journal", database: database) {
            try execute(
                database,
                """
                DELETE FROM capture_journal WHERE frameId IN (
                  SELECT id FROM frame WHERE segmentId=\(segmentID)
                )
                """)
        }
        for documentID in documentIDs {
            try execute(database, "DELETE FROM searchRanking WHERE rowid=\(documentID)")
            try execute(database, "DELETE FROM search WHERE rowid=\(documentID)")
            try execute(database, "DELETE FROM searchOffsets WHERE rowid=\(documentID)")
        }
        try execute(
            database,
            """
            DELETE FROM transcript_word WHERE segmentId=\(segmentID);
            DELETE FROM audio WHERE segmentId=\(segmentID);
            DELETE FROM frame WHERE segmentId=\(segmentID);
            """)
        if deleteDimensions {
            if try tableExists("video_frame_bounds", database: database) {
                try execute(
                    database,
                    "DELETE FROM video_frame_bounds WHERE videoId=\(videoID)"
                )
            }
            try execute(
                database,
                """
                DELETE FROM video WHERE id=\(videoID)
                  AND NOT EXISTS(SELECT 1 FROM frame WHERE videoId=\(videoID));
                DELETE FROM segment WHERE id=\(segmentID) AND type=1;
                """)
        }
    }

    private static func shardPayloadCounts(
        at url: URL,
        keyFileURL: URL
    ) throws -> ShardPayloadCounts {
        try withKeyedDatabase(url: url, keyFileURL: keyFileURL) { database in
            let frameCount = try scalar(database, "SELECT COUNT(*) FROM frame")
            return .init(
                frames: frameCount,
                nodes: try scalar(database, "SELECT COUNT(*) FROM node"),
                documents: try scalar(database, "SELECT COUNT(*) FROM doc_segment"),
                minFrameID: try optionalScalar(database, "SELECT MIN(id) FROM frame"),
                maxFrameID: try optionalScalar(database, "SELECT MAX(id) FROM frame"),
                calendarHours: try pairs(
                    database,
                    """
                    SELECT substr(createdAt,1,13),MIN(createdAt)
                      FROM frame GROUP BY substr(createdAt,1,13) ORDER BY 1
                    """)
            )
        }
    }

    private static func finalizeShardReplacement(
        _ plan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws {
        guard let shardID = plan.shardID,
            let ordinal = plan.shardOrdinal,
            let relativePath = plan.shardRelativePath,
            let priorSHA = plan.shardPriorSHA256,
            let replacementSHA = plan.shardReplacementSHA256,
            let replacementBytes = plan.shardReplacementByteCount
        else {
            throw LibreReverseMeetingDeletionError.database("incomplete shard replacement plan")
        }
        let shardURL = try safeShardURL(relativePath, configuration: configuration)
        guard try ArchiveIntegrityEngine.hash(file: shardURL).sha256 == replacementSHA else {
            throw LibreReverseMeetingDeletionError.database(
                "installed shard no longer matches journal")
        }
        let counts = try shardPayloadCounts(at: shardURL, keyFileURL: configuration.keyFileURL)
        try withDatabase(configuration) { database in
            // Stars are mutable primary-catalog overlays; the sealed frame's
            // isStarred value is only its original snapshot. Keep current
            // overlays for surviving IDs, including edits made after sealing.
            var attachment: OpaquePointer?
            try prepare(database, "ATTACH DATABASE ? AS meeting_replacement KEY ?", &attachment)
            let attach = try unwrap(attachment, database)
            do {
                bind(shardURL.path, to: attach, index: 1)
                bind(try Data(contentsOf: configuration.keyFileURL), to: attach, index: 2)
                try stepDone(attach, database)
            } catch {
                sqlite3_finalize(attach)
                throw error
            }
            sqlite3_finalize(attach)
            defer { try? execute(database, "DETACH DATABASE meeting_replacement") }
            try execute(database, "BEGIN IMMEDIATE")
            do {
                guard try pendingPlan(segmentID: plan.segmentID, database: database) == plan else {
                    throw LibreReverseMeetingDeletionError.database("deletion journal changed")
                }
                var statement: OpaquePointer?
                try prepare(
                    database,
                    """
                    SELECT COUNT(*) FROM library_shard
                     WHERE id=? AND state='sealed_local' AND relativePath=? AND sha256=?
                    """, &statement)
                var value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, shardID)
                bind(relativePath, to: value, index: 2)
                bind(priorSHA, to: value, index: 3)
                guard sqlite3_step(value) == SQLITE_ROW,
                    sqlite3_column_int64(value, 0) == 1
                else {
                    sqlite3_finalize(value)
                    throw LibreReverseMeetingDeletionError.database(
                        "shard catalog changed outside its deletion journal"
                    )
                }
                sqlite3_finalize(value)
                statement = nil
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
                    """, &statement)
                value = try unwrap(statement, database)
                bind(dateString(Date()), to: value, index: 1)
                sqlite3_bind_int64(value, 2, shardID)
                try stepDone(value, database)
                sqlite3_finalize(value)
                statement = nil

                try prepare(
                    database,
                    """
                    UPDATE library_shard SET byteCount=?,sha256=?,frameCount=?,nodeCount=?,
                      documentCount=?,minFrameId=?,maxFrameId=?,remoteIdentifier=NULL,
                      remoteVersion=NULL,remoteSHA256=NULL,verifiedAt=NULL,lastError=NULL
                     WHERE id=?
                    """, &statement)
                value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, replacementBytes)
                bind(replacementSHA, to: value, index: 2)
                sqlite3_bind_int64(value, 3, counts.frames)
                sqlite3_bind_int64(value, 4, counts.nodes)
                sqlite3_bind_int64(value, 5, counts.documents)
                bindOptional(counts.minFrameID, to: value, index: 6)
                bindOptional(counts.maxFrameID, to: value, index: 7)
                sqlite3_bind_int64(value, 8, shardID)
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
                    """, &statement)
                value = try unwrap(statement, database)
                sqlite3_bind_int64(value, 1, ordinal)
                bind(replacementSHA, to: value, index: 2)
                sqlite3_bind_int64(value, 3, replacementBytes)
                bind(dateString(Date()), to: value, index: 4)
                sqlite3_bind_int64(value, 5, shardID)
                try stepDone(value, database)
                sqlite3_finalize(value)

                try execute(database, """
                    DELETE FROM shard_star WHERE shardId=\(shardID)
                      AND NOT EXISTS(SELECT 1 FROM meeting_replacement.frame f
                                     WHERE f.id=shard_star.frameId)
                    """)
                try execute(database, "DELETE FROM shard_calendar_hour WHERE shardId=\(shardID)")
                for item in counts.calendarHours {
                    var row: OpaquePointer?
                    try prepare(
                        database,
                        "INSERT INTO shard_calendar_hour(shardId,hourKey,sampleCreatedAt) VALUES(?,?,?)",
                        &row)
                    let value = try unwrap(row, database)
                    sqlite3_bind_int64(value, 1, shardID)
                    bind(item.hour, to: value, index: 2)
                    bind(item.sample, to: value, index: 3)
                    try stepDone(value, database)
                    sqlite3_finalize(value)
                }
                try execute(
                    database,
                    """
                    DELETE FROM summary WHERE eventId IN (
                      SELECT id FROM event WHERE segmentID=\(plan.segmentID)
                    );
                    DELETE FROM event WHERE segmentID=\(plan.segmentID);
                    DELETE FROM archive_transfer WHERE archiveObjectId IN (
                      SELECT id FROM archive_object WHERE videoId=\(plan.videoID)
                    );
                    DELETE FROM archive_object WHERE videoId=\(plan.videoID);
                    DELETE FROM media_residency WHERE videoId=\(plan.videoID);
                    DELETE FROM video_frame_bounds WHERE videoId=\(plan.videoID);
                    DELETE FROM video WHERE id=\(plan.videoID);
                    DELETE FROM segment WHERE id=\(plan.segmentID) AND type=1;
                    UPDATE meeting_deletion SET state='database_deleted',updatedAt='\(sql(dateString(Date())))'
                     WHERE segmentId=\(plan.segmentID);
                    """)
                guard
                    try scalar(database, "SELECT COUNT(*) FROM segment WHERE id=\(plan.segmentID)")
                        == 0,
                    try scalar(database, "SELECT COUNT(*) FROM video WHERE id=\(plan.videoID)") == 0
                else {
                    throw LibreReverseMeetingDeletionError.database(
                        "primary meeting catalog rows survived shard deletion"
                    )
                }
                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private static func safeShardURL(
        _ relativePath: String,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> URL {
        let root = configuration.databaseURL.deletingLastPathComponent().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: url.path) else {
            throw LibreReverseMeetingDeletionError.database("unsafe or missing meeting shard")
        }
        return url
    }

    private static func withKeyedDatabase<T>(
        url: URL,
        keyFileURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let key = try Data(contentsOf: keyFileURL)
        var raw: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK, let database = raw
        else {
            throw LibreReverseMeetingDeletionError.database("unable to open meeting shard")
        }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) })
                == SQLITE_OK
        else {
            throw LibreReverseMeetingDeletionError.database("unable to unlock meeting shard")
        }
        return try operation(database)
    }

    private static func withWritableKeyedDatabase<T>(
        url: URL,
        keyFileURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let key = try Data(contentsOf: keyFileURL)
        var raw: OpaquePointer?
        guard
            sqlite3_open_v2(
                url.path,
                &raw,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let database = raw
        else {
            throw LibreReverseMeetingDeletionError.database(
                "unable to open writable meeting shard"
            )
        }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({
                sqlite3_key(database, $0.baseAddress, Int32($0.count))
            }) == SQLITE_OK
        else {
            throw LibreReverseMeetingDeletionError.database("unable to unlock meeting shard")
        }
        try execute(database, "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON")
        return try operation(database)
    }

    private static func pendingPlan(
        segmentID: Int64,
        database: OpaquePointer
    ) throws -> LibreReverseMeetingDeletionPlan? {
        var statement: OpaquePointer?
        try prepare(database, "SELECT planJSON FROM meeting_deletion WHERE segmentId=?", &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, segmentID)
        guard sqlite3_step(value) == SQLITE_ROW else { return nil }
        return try JSONDecoder().decode(
            LibreReverseMeetingDeletionPlan.self,
            from: data(value, column: 0)
        )
    }

    private static func deletionState(
        segmentID: Int64,
        database: OpaquePointer
    ) throws -> String? {
        var statement: OpaquePointer?
        try prepare(database, "SELECT state FROM meeting_deletion WHERE segmentId=?", &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, segmentID)
        guard sqlite3_step(value) == SQLITE_ROW else { return nil }
        return optionalString(value, column: 0)
    }

    private static func safeMediaURL(
        _ plan: LibreReverseMeetingDeletionPlan,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> URL {
        guard
            VideoStorage.isCanonicalRelativePath(
                plan.relativeMediaPath,
                xid: plan.xid
            )
        else { throw LibreReverseMeetingDeletionError.unsafeMediaPath(plan.relativeMediaPath) }
        let root = configuration.mediaRoot.standardizedFileURL
        let url = root.appendingPathComponent(plan.relativeMediaPath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else {
            throw LibreReverseMeetingDeletionError.unsafeMediaPath(plan.relativeMediaPath)
        }
        return url
    }

    private static func withDatabase<T>(
        _ configuration: LibreReverseLibraryConfiguration,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try LibreReverseArchiveStore.initialize(configuration)
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
            throw LibreReverseMeetingDeletionError.database("unable to open library")
        }
        defer { sqlite3_close(database) }
        guard
            key.withUnsafeBytes({ sqlite3_key(database, $0.baseAddress, Int32($0.count)) })
                == SQLITE_OK
        else {
            throw LibreReverseMeetingDeletionError.database("unable to unlock library")
        }
        try execute(database, "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON")
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
            let text =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LibreReverseMeetingDeletionError.database(text)
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
    private static func int64s(_ database: OpaquePointer, _ sql: String) throws -> [Int64] {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        var result: [Int64] = []
        while sqlite3_step(value) == SQLITE_ROW { result.append(sqlite3_column_int64(value, 0)) }
        return result
    }
    private static func optionalScalar(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { throw error(database) }
        return optionalInt64(value, column: 0)
    }
    private static func tableExists(
        _ table: String,
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            database, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", &statement
        )
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        bind(table, to: value, index: 1)
        guard sqlite3_step(value) == SQLITE_ROW else { throw error(database) }
        return sqlite3_column_int64(value, 0) == 1
    }
    private static func pairs(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> [(String, String)] {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        var result: [(String, String)] = []
        while sqlite3_step(value) == SQLITE_ROW {
            result.append((string(value, column: 0), string(value, column: 1)))
        }
        return result
    }
    private static func intStringPairs(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> [(Int64, String)] {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        var result: [(Int64, String)] = []
        while sqlite3_step(value) == SQLITE_ROW {
            result.append((sqlite3_column_int64(value, 0), string(value, column: 1)))
        }
        return result
    }
    private static func error(_ database: OpaquePointer) -> LibreReverseMeetingDeletionError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(
            statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private static func bind(_ value: Data, to statement: OpaquePointer, index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement, index, bytes.baseAddress, Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
    private static func bindOptional(
        _ value: Int64?,
        to statement: OpaquePointer,
        index: Int32
    ) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    private static func string(_ statement: OpaquePointer, column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }
    private static func optionalString(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : string(statement, column: column)
    }
    private static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, column)
    }
    private static func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
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
