#if os(macOS)
import CSQLCipher
import Foundation

public struct LibreReverseShardBuildProgress: Equatable, Sendable {
    public enum Phase: String, CaseIterable, Sendable {
        case frames
        case dimensions
        case nodes
        case documents
        case search
        case relatedMedia = "related_media"
        case indexes
        case verify
        case complete
    }

    public let phase: Phase
    public let completedRows: Int64
    public let totalRows: Int64

    public var fractionCompleted: Double {
        guard totalRows > 0 else { return phase == .complete ? 1 : 0 }
        return min(max(Double(completedRows) / Double(totalRows), 0), 1)
    }
}

public struct LibreReverseShardManifest: Equatable, Sendable {
    public let url: URL
    public let interval: LibreReverseShardInterval
    public let byteCount: Int64
    public let sha256: String
    public let frameCount: Int64
    public let nodeCount: Int64
    public let documentCount: Int64
    public let audioCount: Int64
    public let transcriptWordCount: Int64
    public let minFrameID: Int64?
    public let maxFrameID: Int64?
}

public struct LibreReverseShardCatalogEntry: Equatable, Sendable {
    public let manifest: LibreReverseShardManifest
    public let relativePath: String

    public init(manifest: LibreReverseShardManifest, relativePath: String) {
        self.manifest = manifest
        self.relativePath = relativePath
    }
}

public struct LibreReversePrimaryManifest: Equatable, Sendable {
    public let url: URL
    public let activeInterval: LibreReverseShardInterval
    public let byteCount: Int64
    public let sha256: String
    public let activeFrameCount: Int64
    public let activeNodeCount: Int64
    public let activeDocumentCount: Int64
}

public enum LibreReverseShardBuilderError: Error, Equatable {
    case sourceAndDestinationMatch
    case invalidBatchSize
    case unableToOpenDatabase(String)
    case unableToApplyKey(Int32)
    case sqlite(String)
    case sourceChanged
    case incompatibleBuild
    case incompleteBuild
    case pendingOCRFrames(Int)
    case integrity(String)
}

/// Restartable, bounded-transaction partitioner for a closed 30-day interval.
///
/// Each `advance` call commits at most one bounded batch or one metadata phase.
/// The destination itself owns the durable checkpoint, so process termination
/// cannot make the catalog claim progress which is not present in the shard.
public enum LibreReverseShardBuilder {
    public static let defaultBatchSize = 10_000

    public static func prepare(
        source: LibreReverseLibraryConfiguration,
        destinationURL: URL,
        interval: LibreReverseShardInterval
    ) throws {
        guard source.databaseURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw LibreReverseShardBuilderError.sourceAndDestinationMatch
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try requireNoPendingOCR(source: source, interval: interval)
        let sourceStats = try sourceFrameStats(source, interval: interval)
        try withDatabase(url: destinationURL, keyFileURL: source.keyFileURL, create: true) {
            database in
            try execute(database, "PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=OFF")
            try execute(database, shardSchemaSQL)
            let existing = try scalarInt64(database, "SELECT COUNT(*) FROM shard_build_manifest")
            if existing == 0 {
                var statement: OpaquePointer?
                try prepare(database, """
                    INSERT INTO shard_build_manifest(
                      id,intervalStart,intervalEnd,ordinal,sourcePath,
                      sourceFrameMax,sourceFrameCount,state
                    ) VALUES(1,?,?,?,?,?,?,'building')
                    """, &statement)
                let value = try unwrap(statement, database)
                defer { sqlite3_finalize(value) }
                bind(databaseString(interval.start), to: value, index: 1)
                bind(databaseString(interval.end), to: value, index: 2)
                sqlite3_bind_int64(value, 3, interval.ordinal)
                bind(source.databaseURL.standardizedFileURL.path, to: value, index: 4)
                sqlite3_bind_int64(value, 5, sourceStats.maxID)
                sqlite3_bind_int64(value, 6, sourceStats.count)
                try stepDone(value, database)
                try seedPhases(database)
            } else {
                guard try buildMatches(
                    database: database,
                    source: source,
                    interval: interval,
                    sourceStats: sourceStats
                ) else { throw LibreReverseShardBuilderError.incompatibleBuild }
            }
        }
    }

    /// Advances one bounded unit. Call until the returned phase is `.complete`.
    @discardableResult
    public static func advance(
        source: LibreReverseLibraryConfiguration,
        destinationURL: URL,
        interval: LibreReverseShardInterval,
        batchSize: Int = defaultBatchSize
    ) throws -> LibreReverseShardBuildProgress {
        guard batchSize > 0 && batchSize <= 250_000 else {
            throw LibreReverseShardBuilderError.invalidBatchSize
        }
        let sourceStats = try sourceFrameStats(source, interval: interval)
        return try withDatabase(
            url: destinationURL,
            keyFileURL: source.keyFileURL,
            create: false
        ) { database in
            guard try buildMatches(
                database: database,
                source: source,
                interval: interval,
                sourceStats: sourceStats
            ) else { throw LibreReverseShardBuilderError.sourceChanged }
            try attachSource(source, to: database)
            defer { try? execute(database, "DETACH DATABASE source") }
            let phase = try currentPhase(database)
            switch phase {
            case .frames:
                try copyFrameBatch(
                    database,
                    interval: interval,
                    batchSize: batchSize
                )
            case .dimensions:
                try copyDimensions(database)
                try completePhase(.dimensions, database: database)
            case .nodes:
                try copyNodeBatch(database, batchSize: batchSize)
            case .documents:
                try copyDocuments(database, interval: interval)
                try completePhase(.documents, database: database)
            case .search:
                try copySearchBatch(database, batchSize: batchSize)
            case .relatedMedia:
                try copyRelatedMedia(database, interval: interval)
                try completePhase(.relatedMedia, database: database)
            case .indexes:
                try buildNextIndex(database)
            case .verify:
                if try verifyNextStep(database, interval: interval) {
                    try completePhase(.verify, database: database)
                }
            case .complete:
                break
            }
            return try progress(database)
        }
    }

    public static func buildToCompletion(
        source: LibreReverseLibraryConfiguration,
        destinationURL: URL,
        interval: LibreReverseShardInterval,
        batchSize: Int = defaultBatchSize,
        progressHandler: ((LibreReverseShardBuildProgress) throws -> Void)? = nil
    ) throws -> LibreReverseShardManifest {
        try prepare(source: source, destinationURL: destinationURL, interval: interval)
        while true {
            let current = try advance(
                source: source,
                destinationURL: destinationURL,
                interval: interval,
                batchSize: batchSize
            )
            try progressHandler?(current)
            if current.phase == .complete { break }
        }
        return try seal(
            source: source,
            destinationURL: destinationURL,
            interval: interval
        )
    }

    public static func seal(
        source: LibreReverseLibraryConfiguration,
        destinationURL: URL,
        interval: LibreReverseShardInterval
    ) throws -> LibreReverseShardManifest {
        try requireNoPendingOCR(source: source, interval: interval)
        let counts = try withDatabase(
            url: destinationURL,
            keyFileURL: source.keyFileURL,
            create: false
        ) { database -> (Int64, Int64, Int64, Int64, Int64, Int64?, Int64?) in
            guard try currentPhase(database) == .complete else {
                throw LibreReverseShardBuilderError.incompleteBuild
            }
            try execute(database, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
            if let violation = try cipherIntegrityViolation(database) {
                throw LibreReverseShardBuilderError.integrity(
                    "sealed shard cipher integrity failed: \(violation)"
                )
            }
            if let violation = try foreignKeyViolation(database) {
                throw LibreReverseShardBuilderError.integrity(
                    "sealed shard foreign key failed: \(violation)"
                )
            }
            var statement: OpaquePointer?
            try prepare(database, """
                SELECT COUNT(*),
                       (SELECT COUNT(*) FROM node),
                       (SELECT COUNT(*) FROM doc_segment),
                       (SELECT COUNT(*) FROM audio),
                       (SELECT COUNT(*) FROM transcript_word),
                       MIN(id),MAX(id)
                  FROM frame
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            return (
                sqlite3_column_int64(value, 0),
                sqlite3_column_int64(value, 1),
                sqlite3_column_int64(value, 2),
                sqlite3_column_int64(value, 3),
                sqlite3_column_int64(value, 4),
                optionalInt64(value, column: 5),
                optionalInt64(value, column: 6)
            )
        }
        let integrity = try ArchiveIntegrityEngine.hash(file: destinationURL)
        return LibreReverseShardManifest(
            url: destinationURL,
            interval: interval,
            byteCount: integrity.byteCount,
            sha256: integrity.sha256,
            frameCount: counts.0,
            nodeCount: counts.1,
            documentCount: counts.2,
            audioCount: counts.3,
            transcriptWordCount: counts.4,
            minFrameID: counts.5,
            maxFrameID: counts.6
        )
    }

    /// Builds the compact catalog/current-interval database used after cutover.
    /// The source remains untouched and authoritative until the caller atomically
    /// installs the returned, fully verified file.
    public static func buildReplacementPrimary(
        source: LibreReverseLibraryConfiguration,
        destinationURL: URL,
        activeInterval: LibreReverseShardInterval,
        sealedShards: [LibreReverseShardCatalogEntry]
    ) throws -> LibreReversePrimaryManifest {
        guard source.databaseURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw LibreReverseShardBuilderError.sourceAndDestinationMatch
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw LibreReverseShardBuilderError.sqlite("replacement primary already exists")
        }
        for entry in sealedShards {
            guard isSafeRelativePath(entry.relativePath) else {
                throw LibreReverseShardBuilderError.integrity("unsafe shard catalog path")
            }
            let actual = try ArchiveIntegrityEngine.hash(file: entry.manifest.url)
            guard actual.byteCount == entry.manifest.byteCount,
                  actual.sha256 == entry.manifest.sha256 else {
                throw LibreReverseShardBuilderError.integrity(
                    "sealed shard changed: \(entry.manifest.url.lastPathComponent)"
                )
            }
        }

        let destination = LibreReverseLibraryConfiguration(
            databaseURL: destinationURL,
            keyFileURL: source.keyFileURL,
            mediaRoot: source.mediaRoot
        )
        try LibreReverseLibraryStore.initialize(destination)
        try withDatabase(url: destinationURL, keyFileURL: source.keyFileURL, create: false) {
            database in
            try execute(database, """
                PRAGMA foreign_keys=OFF;
                PRAGMA synchronous=NORMAL;
                PRAGMA temp_store=MEMORY;
                PRAGMA cache_size=-262144;
                """)
            try attachSource(source, to: database)
            defer { try? execute(database, "DETACH DATABASE source") }
            try transaction(database) {
                for table in primaryCatalogTables {
                    try copyWholeTableIfPresent(table, database: database)
                }
                try copyActivePayload(database, interval: activeInterval)
                try execute(database, "CREATE INDEX IF NOT EXISTS index_node_on_frameid ON node(frameId)")
                try populateShardCatalog(
                    database,
                    activeInterval: activeInterval,
                    sealedShards: sealedShards
                )
                try preservePrimarySequences(database)
            }
            try verifyReplacementPrimary(
                database,
                activeInterval: activeInterval,
                sealedShards: sealedShards
            )
            // The install operation moves one file. Make every committed page
            // part of that file and leave no correctness dependency on a WAL
            // or SHM sidecar at the temporary build path.
            // Schema qualification avoids checkpointing the attached read-only
            // source monolith, which would fail while trying to truncate its WAL.
            try execute(
                database,
                "PRAGMA main.wal_checkpoint(TRUNCATE); PRAGMA main.journal_mode=DELETE"
            )
        }
        let integrity = try ArchiveIntegrityEngine.hash(file: destinationURL)
        let counts = try withDatabase(
            url: destinationURL,
            keyFileURL: source.keyFileURL,
            create: false
        ) { database in
            (
                try scalarInt64(database, "SELECT COUNT(*) FROM frame"),
                try scalarInt64(database, "SELECT COUNT(*) FROM node"),
                try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment")
            )
        }
        return LibreReversePrimaryManifest(
            url: destinationURL,
            activeInterval: activeInterval,
            byteCount: integrity.byteCount,
            sha256: integrity.sha256,
            activeFrameCount: counts.0,
            activeNodeCount: counts.1,
            activeDocumentCount: counts.2
        )
    }

    /// Closes the monolith's WAL dependency immediately before the atomic
    /// filename swap. Call only after capture and every product DB session are
    /// stopped; the returned hash identifies the retired standalone file.
    public static func prepareSourceForCutover(
        _ source: LibreReverseLibraryConfiguration
    ) throws -> ArchiveIntegrity {
        try withDatabase(
            url: source.databaseURL,
            keyFileURL: source.keyFileURL,
            create: false
        ) { database in
            try execute(database, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
            if let violation = try cipherIntegrityViolation(database) {
                throw LibreReverseShardBuilderError.integrity(
                    "source cipher integrity failed: \(violation)"
                )
            }
        }
        return try ArchiveIntegrityEngine.hash(file: source.databaseURL)
    }

    private static func copyFrameBatch(
        _ database: OpaquePointer,
        interval: LibreReverseShardInterval,
        batchSize: Int
    ) throws {
        let lastKey = try phaseLastKey(.frames, database: database)
        let nextMax = try nextKey(
            database,
            sql: """
                SELECT MAX(id) FROM (
                  SELECT id FROM source.frame
                   WHERE createdAt>=? AND createdAt<? AND id>?
                   ORDER BY id LIMIT ?
                )
                """,
            strings: [databaseString(interval.start), databaseString(interval.end)],
            lastKey: lastKey,
            limit: batchSize
        )
        guard let nextMax else {
            try completePhase(.frames, database: database)
            return
        }
        try transaction(database) {
            var statement: OpaquePointer?
            try prepare(database, """
                INSERT OR IGNORE INTO frame
                SELECT * FROM source.frame
                 WHERE createdAt>=? AND createdAt<? AND id>? AND id<=?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseString(interval.start), to: value, index: 1)
            bind(databaseString(interval.end), to: value, index: 2)
            sqlite3_bind_int64(value, 3, lastKey)
            sqlite3_bind_int64(value, 4, nextMax)
            try stepDone(value, database)
            try updatePhase(
                .frames,
                lastKey: nextMax,
                completedRows: try scalarInt64(database, "SELECT COUNT(*) FROM frame"),
                totalRows: try scalarInt64(database, """
                    SELECT COUNT(*) FROM source.frame
                     WHERE createdAt>='\(sql(databaseString(interval.start)))'
                       AND createdAt<'\(sql(databaseString(interval.end)))'
                    """),
                database: database
            )
        }
    }

    private static func copyDimensions(_ database: OpaquePointer) throws {
        try transaction(database) {
            try execute(database, """
                INSERT OR IGNORE INTO segment
                SELECT s.* FROM source.segment s
                 WHERE s.id IN (SELECT DISTINCT segmentId FROM frame WHERE segmentId IS NOT NULL);
                INSERT OR IGNORE INTO video(
                  id,height,width,path,captureType,fileSize,frameRate,local,
                  uploadedAt,xid,processingState
                )
                SELECT v.id,v.height,v.width,v.path,v.captureType,v.fileSize,
                       v.frameRate,v.local,v.uploadedAt,v.xid,v.processingState
                  FROM source.video v
                 WHERE v.id IN (SELECT DISTINCT videoId FROM frame WHERE videoId IS NOT NULL);
                """)
        }
    }

    private static func copyNodeBatch(_ database: OpaquePointer, batchSize: Int) throws {
        let lastFrameID = try phaseLastKey(.nodes, database: database)
        let nextFrameID = try optionalScalarInt64(database, """
            SELECT MAX(id) FROM (
              SELECT id FROM frame WHERE id>\(lastFrameID) ORDER BY id LIMIT \(batchSize)
            )
            """)
        guard let nextFrameID else {
            try completePhase(.nodes, database: database)
            return
        }
        try transaction(database) {
            try execute(database, """
                INSERT OR IGNORE INTO node
                SELECT n.* FROM source.node n
                 WHERE n.frameId>\(lastFrameID) AND n.frameId<=\(nextFrameID)
                   AND n.frameId IN (
                     SELECT id FROM frame WHERE id>\(lastFrameID) AND id<=\(nextFrameID)
                   )
                """)
            try updatePhase(
                .nodes,
                lastKey: nextFrameID,
                completedRows: try scalarInt64(database, "SELECT COUNT(*) FROM node"),
                totalRows: 0,
                database: database
            )
        }
    }

    private static func copyDocuments(
        _ database: OpaquePointer,
        interval: LibreReverseShardInterval
    ) throws {
        try transaction(database) {
            var statement: OpaquePointer?
            try prepare(database, """
                INSERT OR IGNORE INTO doc_segment
                SELECT d.* FROM source.doc_segment d
                 WHERE d.frameId IN (SELECT id FROM frame)
                    OR (d.frameId IS NULL AND d.segmentId IN (
                      SELECT id FROM source.segment WHERE startDate>=? AND startDate<?
                    ))
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseString(interval.start), to: value, index: 1)
            bind(databaseString(interval.end), to: value, index: 2)
            try stepDone(value, database)
            // Null-frame documents can introduce a segment not referenced by a
            // frame. Bring that small dimension row into the shard as well.
            try execute(database, """
                INSERT OR IGNORE INTO segment
                SELECT s.* FROM source.segment s
                 WHERE s.id IN (SELECT segmentId FROM doc_segment)
                """)
            try updatePhase(
                .documents,
                lastKey: 0,
                completedRows: try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment"),
                totalRows: try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment"),
                database: database
            )
        }
    }

    private static func copySearchBatch(_ database: OpaquePointer, batchSize: Int) throws {
        let lastDocID = try phaseLastKey(.search, database: database)
        let nextDocID = try optionalScalarInt64(database, """
            SELECT MAX(docid) FROM (
              SELECT docid FROM doc_segment WHERE docid>\(lastDocID)
               ORDER BY docid LIMIT \(batchSize)
            )
            """)
        guard let nextDocID else {
            try completePhase(.search, database: database)
            return
        }
        try transaction(database) {
            try execute(database, """
                INSERT INTO searchRanking(rowid,text,otherText,title)
                SELECT r.rowid,r.text,r.otherText,r.title
                  FROM source.searchRanking r
                 WHERE r.rowid>\(lastDocID) AND r.rowid<=\(nextDocID)
                   AND r.rowid IN (
                     SELECT docid FROM doc_segment
                     WHERE docid>\(lastDocID) AND docid<=\(nextDocID)
                   );
                INSERT INTO search(rowid,text,otherText)
                SELECT r.rowid,r.text,r.otherText
                  FROM source.search r
                 WHERE r.rowid>\(lastDocID) AND r.rowid<=\(nextDocID)
                   AND r.rowid IN (
                     SELECT docid FROM doc_segment
                      WHERE docid>\(lastDocID) AND docid<=\(nextDocID)
                   );
                INSERT INTO searchOffsets(rowid,text,otherText)
                SELECT r.rowid,r.text,r.otherText
                  FROM source.searchOffsets r
                 WHERE r.rowid>\(lastDocID) AND r.rowid<=\(nextDocID)
                   AND r.rowid IN (
                     SELECT docid FROM doc_segment
                      WHERE docid>\(lastDocID) AND docid<=\(nextDocID)
                   )
                """)
            try updatePhase(
                .search,
                lastKey: nextDocID,
                completedRows: try scalarInt64(database, "SELECT COUNT(*) FROM searchRanking"),
                totalRows: try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment"),
                database: database
            )
        }
    }

    private static func copyRelatedMedia(
        _ database: OpaquePointer,
        interval: LibreReverseShardInterval
    ) throws {
        try transaction(database) {
            var statement: OpaquePointer?
            try prepare(database, """
                INSERT OR IGNORE INTO audio
                SELECT a.* FROM source.audio a JOIN source.segment s ON s.id=a.segmentId
                 WHERE s.startDate>=? AND s.startDate<?;
                """, &statement)
            var value = try unwrap(statement, database)
            bind(databaseString(interval.start), to: value, index: 1)
            bind(databaseString(interval.end), to: value, index: 2)
            try stepDone(value, database)
            sqlite3_finalize(value)
            statement = nil
            try prepare(database, """
                INSERT OR IGNORE INTO transcript_word
                SELECT w.* FROM source.transcript_word w
                JOIN source.segment s ON s.id=w.segmentId
                 WHERE s.startDate>=? AND s.startDate<?;
                """, &statement)
            value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseString(interval.start), to: value, index: 1)
            bind(databaseString(interval.end), to: value, index: 2)
            try stepDone(value, database)
            try updatePhase(
                .relatedMedia,
                lastKey: 0,
                completedRows: try scalarInt64(database, """
                    SELECT (SELECT COUNT(*) FROM audio)+(SELECT COUNT(*) FROM transcript_word)
                    """),
                totalRows: 0,
                database: database
            )
        }
    }

    private static func buildNextIndex(_ database: OpaquePointer) throws {
        let index = Int(try phaseLastKey(.indexes, database: database))
        guard index < shardIndexes.count else {
            try completePhase(.indexes, database: database)
            return
        }
        try execute(database, shardIndexes[index])
        try updatePhase(
            .indexes,
            lastKey: Int64(index + 1),
            completedRows: Int64(index + 1),
            totalRows: Int64(shardIndexes.count),
            database: database
        )
    }

    private static let primaryCatalogTables = [
        "segment", "video", "video_frame_bounds",
        "event", "summary", "librereverse_summary_retry",
        "archive_destination", "archive_policy",
        "archive_object", "archive_transfer", "media_residency", "archive_library",
        "archive_credential",
        "capture_journal", "archive_download_request", "document_id_sequence",
    ]

    private static func preservePrimarySequences(_ database: OpaquePointer) throws {
        // Table copying restores only the maximum surviving row, not SQLite's
        // allocation watermark. Preserve deleted/sealed IDs for every table.
        try execute(database, """
            UPDATE sqlite_sequence SET seq=MAX(seq,
              COALESCE((SELECT MAX(source.seq) FROM source.sqlite_sequence source
                         WHERE source.name=sqlite_sequence.name),0));
            INSERT INTO sqlite_sequence(name,seq)
            SELECT source.name,source.seq FROM source.sqlite_sequence source
             WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence current WHERE current.name=source.name)
               AND EXISTS(SELECT 1 FROM sqlite_master t WHERE t.type='table' AND t.name=source.name);
            """)
        try LibreReverseLibraryStore.ensureFrameIDHighWatermark(database)
    }

    private static func requireNoPendingOCR(
        source: LibreReverseLibraryConfiguration,
        interval: LibreReverseShardInterval
    ) throws {
        let count = try withDatabase(url: source.databaseURL, keyFileURL: source.keyFileURL, create: false) { database in
            try scalarInt64(database, """
                SELECT COUNT(*) FROM frame_processing p JOIN frame f ON f.id=p.id
                 WHERE p.processingType='ocr'
                   AND f.createdAt>='\(sql(databaseString(interval.start)))'
                   AND f.createdAt<'\(sql(databaseString(interval.end)))'
                """)
        }
        guard count == 0 else { throw LibreReverseShardBuilderError.pendingOCRFrames(Int(count)) }
    }

    private static func copyWholeTableIfPresent(
        _ table: String,
        database: OpaquePointer
    ) throws {
        let exists = try scalarInt64(database, """
            SELECT COUNT(*) FROM source.sqlite_master
             WHERE type='table' AND name='\(sql(table))'
            """)
        guard exists == 1 else { return }
        if table == "archive_download_request" {
            try execute(database, "CREATE TABLE IF NOT EXISTS archive_download_request(id TEXT PRIMARY KEY,createdAt REAL NOT NULL,payload TEXT NOT NULL)")
        }
        try execute(database, "DELETE FROM \(table)")
        if table == "video" {
            // Match canonical columns by name; physical column order may differ.
            try execute(database, """
                INSERT INTO video(
                  id,height,width,path,captureType,fileSize,frameRate,local,
                  uploadedAt,xid,processingState
                )
                SELECT id,height,width,path,captureType,fileSize,frameRate,local,
                       uploadedAt,xid,processingState
                  FROM source.video
                """)
        } else if table == "archive_transfer" {
            // A transfer has no independent user payload. Old interrupted work
            // can outlive an archive object deleted during media repair; do not
            // carry an unusable dangling job into the strict replacement DB.
            try execute(database, """
                INSERT INTO archive_transfer
                SELECT transfer.* FROM source.archive_transfer transfer
                 WHERE EXISTS(
                   SELECT 1 FROM source.archive_object object
                    WHERE object.id=transfer.archiveObjectId
                 )
                """)
        } else {
            try execute(database, "INSERT INTO \(table) SELECT * FROM source.\(table)")
        }
    }

    private static func copyActivePayload(
        _ database: OpaquePointer,
        interval: LibreReverseShardInterval
    ) throws {
        let start = sql(databaseString(interval.start))
        let end = sql(databaseString(interval.end))
        try execute(database, """
            INSERT INTO frame SELECT * FROM source.frame
             WHERE createdAt>='\(start)' AND createdAt<'\(end)';
            INSERT INTO frame_processing SELECT p.* FROM source.frame_processing p
             WHERE p.id IN (SELECT id FROM frame);
            INSERT INTO node SELECT n.* FROM source.node n
             WHERE n.frameId IN (SELECT id FROM frame);
            INSERT INTO doc_segment SELECT d.* FROM source.doc_segment d
             WHERE d.frameId IN (SELECT id FROM frame)
                OR (d.frameId IS NULL AND d.segmentId IN (
                  SELECT id FROM source.segment
                   WHERE startDate>='\(start)' AND startDate<'\(end)'
                ));
            INSERT INTO searchRanking(rowid,text,otherText,title)
            SELECT r.rowid,r.text,r.otherText,r.title FROM source.searchRanking r
             WHERE r.rowid IN (SELECT docid FROM doc_segment);
            INSERT INTO search(rowid,text,otherText)
            SELECT r.rowid,r.text,r.otherText FROM source.search r
             WHERE r.rowid IN (SELECT docid FROM doc_segment);
            INSERT INTO searchOffsets(rowid,text,otherText)
            SELECT r.rowid,r.text,r.otherText FROM source.searchOffsets r
             WHERE r.rowid IN (SELECT docid FROM doc_segment);
            INSERT INTO audio SELECT a.* FROM source.audio a
            JOIN source.segment s ON s.id=a.segmentId
             WHERE s.startDate>='\(start)' AND s.startDate<'\(end)';
            INSERT INTO transcript_word SELECT w.* FROM source.transcript_word w
            JOIN source.segment s ON s.id=w.segmentId
             WHERE s.startDate>='\(start)' AND s.startDate<'\(end)';
            """)
    }

    private static func populateShardCatalog(
        _ database: OpaquePointer,
        activeInterval: LibreReverseShardInterval,
        sealedShards: [LibreReverseShardCatalogEntry]
    ) throws {
        let sourceIsSharded = try scalarInt64(database, """
            SELECT COUNT(*) FROM source.shard_metadata
             WHERE id=1 AND routingState='sharded'
            """) == 1
        let sourceHasCalendarHours = try scalarInt64(database, """
            SELECT COUNT(*) FROM source.sqlite_master
             WHERE type='table' AND name='shard_calendar_hour'
            """) == 1
        try execute(database, """
            DELETE FROM shard_archive_object;
            DELETE FROM shard_star;
            DELETE FROM shard_calendar_hour;
            DELETE FROM shard_build_progress;
            DELETE FROM library_shard;
            DELETE FROM shard_metadata;
            INSERT INTO shard_metadata(
              id,epochStart,intervalSeconds,routingState,activeOrdinal
            )
            SELECT id,epochStart,intervalSeconds,'sharded',\(activeInterval.ordinal)
              FROM source.shard_metadata WHERE id=1;
            """)
        if sourceIsSharded {
            // Rollover must retain stable shard identities and all provider
            // metadata. Older shards may be remote-only, so rebuilding their
            // manifests or assigning fresh IDs is both unnecessary and wrong.
            try execute(database, """
                INSERT INTO library_shard SELECT * FROM source.library_shard;
                INSERT INTO shard_star SELECT * FROM source.shard_star;
                INSERT INTO shard_build_progress SELECT * FROM source.shard_build_progress;
                INSERT INTO shard_archive_object SELECT * FROM source.shard_archive_object;
                """)
            // Keep pending deletion of superseded remote payloads across compaction.
            try copyWholeTableIfPresent("shard_archive_retired_object", database: database)
            if sourceHasCalendarHours {
                try execute(
                    database,
                    "INSERT INTO shard_calendar_hour SELECT * FROM source.shard_calendar_hour"
                )
            }
        }
        for entry in sealedShards.sorted(by: {
            $0.manifest.interval.ordinal < $1.manifest.interval.ordinal
        }) {
            let manifest = entry.manifest
            var statement: OpaquePointer?
            try prepare(database, """
                INSERT INTO library_shard(
                  ordinal,generation,relativePath,state,schemaVersion,keyVersion,
                  byteCount,sha256,frameCount,nodeCount,documentCount,minFrameId,
                  maxFrameId,sealedAt
                ) VALUES(?,1,?,'sealed_local',41,1,?,?,?,?,?,?,?,?)
                ON CONFLICT(ordinal,generation) DO UPDATE SET
                  relativePath=excluded.relativePath,state='sealed_local',
                  schemaVersion=excluded.schemaVersion,keyVersion=excluded.keyVersion,
                  byteCount=excluded.byteCount,sha256=excluded.sha256,
                  frameCount=excluded.frameCount,nodeCount=excluded.nodeCount,
                  documentCount=excluded.documentCount,minFrameId=excluded.minFrameId,
                  maxFrameId=excluded.maxFrameId,sealedAt=excluded.sealedAt,lastError=NULL
                RETURNING id
                """, &statement)
            let value = try unwrap(statement, database)
            sqlite3_bind_int64(value, 1, manifest.interval.ordinal)
            bind(entry.relativePath, to: value, index: 2)
            sqlite3_bind_int64(value, 3, manifest.byteCount)
            bind(manifest.sha256, to: value, index: 4)
            sqlite3_bind_int64(value, 5, manifest.frameCount)
            sqlite3_bind_int64(value, 6, manifest.nodeCount)
            sqlite3_bind_int64(value, 7, manifest.documentCount)
            bind(manifest.minFrameID, to: value, index: 8)
            bind(manifest.maxFrameID, to: value, index: 9)
            bind(databaseString(Date()), to: value, index: 10)
            guard sqlite3_step(value) == SQLITE_ROW else {
                sqlite3_finalize(value)
                throw sqliteError(database)
            }
            let shardID = sqlite3_column_int64(value, 0)
            guard sqlite3_step(value) == SQLITE_DONE else {
                sqlite3_finalize(value)
                throw sqliteError(database)
            }
            sqlite3_finalize(value)
            try execute(database, "DELETE FROM shard_star WHERE shardId=\(shardID)")
            try execute(database, "DELETE FROM shard_calendar_hour WHERE shardId=\(shardID)")
            try execute(database, """
                INSERT INTO shard_star(frameId,createdAt,shardId)
                SELECT id,createdAt,\(shardID) FROM source.frame
                 WHERE isStarred=1
                   AND createdAt>='\(sql(databaseString(manifest.interval.start)))'
                   AND createdAt<'\(sql(databaseString(manifest.interval.end)))'
                """)
            // Keep one timestamp per occupied UTC hour in the primary catalog
            // so the date picker can show available days and hours after shard
            // payloads have been evicted to archive storage.
            try execute(database, """
                INSERT INTO shard_calendar_hour(shardId,hourKey,sampleCreatedAt)
                SELECT \(shardID),substr(createdAt,1,13),MIN(createdAt)
                  FROM source.frame
                 WHERE createdAt>='\(sql(databaseString(manifest.interval.start)))'
                   AND createdAt<'\(sql(databaseString(manifest.interval.end)))'
                 GROUP BY substr(createdAt,1,13)
                """)
        }
    }

    private static func verifyReplacementPrimary(
        _ database: OpaquePointer,
        activeInterval: LibreReverseShardInterval,
        sealedShards: [LibreReverseShardCatalogEntry]
    ) throws {
        if let violation = try cipherIntegrityViolation(database) {
            throw LibreReverseShardBuilderError.integrity(
                "replacement cipher integrity failed: \(violation)"
            )
        }
        if let violation = try foreignKeyViolation(database) {
            throw LibreReverseShardBuilderError.integrity(
                "replacement foreign key check failed: \(violation)"
            )
        }
        for table in ["segment", "video", "video_frame_bounds", "event", "summary"] {
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM \(table)",
                source: "SELECT COUNT(*) FROM source.\(table)",
                name: table
            )
        }
        let totals: [(String, Int64)] = [
            ("frame", sealedShards.reduce(0) { $0 + $1.manifest.frameCount }),
            ("node", sealedShards.reduce(0) { $0 + $1.manifest.nodeCount }),
            ("doc_segment", sealedShards.reduce(0) { $0 + $1.manifest.documentCount }),
            ("searchRanking", sealedShards.reduce(0) { $0 + $1.manifest.documentCount }),
            ("audio", sealedShards.reduce(0) { $0 + $1.manifest.audioCount }),
            ("transcript_word", sealedShards.reduce(0) {
                $0 + $1.manifest.transcriptWordCount
            }),
        ]
        for (table, sealedCount) in totals {
            let activeCount = try scalarInt64(database, "SELECT COUNT(*) FROM \(table)")
            let sourceCount = try scalarInt64(database, "SELECT COUNT(*) FROM source.\(table)")
            guard sealedCount + activeCount == sourceCount else {
                throw LibreReverseShardBuilderError.integrity(
                    "union \(table) mismatch \(sealedCount + activeCount) != \(sourceCount)"
                )
            }
        }
        let start = sql(databaseString(activeInterval.start))
        let end = sql(databaseString(activeInterval.end))
        try requireEqualCounts(
            database,
            destination: "SELECT COUNT(*) FROM frame",
            source: "SELECT COUNT(*) FROM source.frame WHERE createdAt>='\(start)' AND createdAt<'\(end)'",
            name: "active frame"
        )
        let documentCount = try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment")
        let searchCount = try scalarInt64(database, "SELECT COUNT(*) FROM searchRanking")
        guard documentCount == searchCount else {
            throw LibreReverseShardBuilderError.integrity("active document/search mismatch")
        }
        var expectedStars = try scalarInt64(database, """
            SELECT CASE WHEN EXISTS(
              SELECT 1 FROM source.shard_metadata
               WHERE id=1 AND routingState='sharded'
            ) THEN (SELECT COUNT(*) FROM source.shard_star) ELSE 0 END
            """)
        for entry in sealedShards {
            expectedStars += try scalarInt64(database, """
                SELECT COUNT(*) FROM source.frame WHERE isStarred=1
                 AND createdAt>='\(sql(databaseString(entry.manifest.interval.start)))'
                 AND createdAt<'\(sql(databaseString(entry.manifest.interval.end)))'
                """)
        }
        guard try scalarInt64(database, "SELECT COUNT(*) FROM shard_star") == expectedStars else {
            throw LibreReverseShardBuilderError.integrity("shard star catalog mismatch")
        }
        for entry in sealedShards {
            let interval = entry.manifest.interval
            let expectedHours = try scalarInt64(database, """
                SELECT COUNT(DISTINCT substr(createdAt,1,13)) FROM source.frame
                 WHERE createdAt>='\(sql(databaseString(interval.start)))'
                   AND createdAt<'\(sql(databaseString(interval.end)))'
                """)
            let indexedHours = try scalarInt64(database, """
                SELECT COUNT(*) FROM shard_calendar_hour h
                  JOIN library_shard s ON s.id=h.shardId
                 WHERE s.ordinal=\(interval.ordinal)
                   AND s.generation=(
                     SELECT MAX(newer.generation) FROM library_shard newer
                      WHERE newer.ordinal=s.ordinal
                   )
                """)
            guard indexedHours == expectedHours else {
                throw LibreReverseShardBuilderError.integrity(
                    "shard calendar-hour catalog mismatch \(indexedHours) != \(expectedHours)"
                )
            }
        }
    }

    /// Performs one durable verification step. Keeping the page scan and the
    /// relationship scan in separate advances makes verification restartable
    /// and prevents an interruption from repeating already completed work.
    private static func verifyNextStep(
        _ database: OpaquePointer,
        interval: LibreReverseShardInterval
    ) throws -> Bool {
        let step = try phaseLastKey(.verify, database: database)
        switch step {
        case 0:
            let outside = try scalarInt64(database, """
                SELECT COUNT(*) FROM frame
                 WHERE createdAt<'\(sql(databaseString(interval.start)))'
                    OR createdAt>='\(sql(databaseString(interval.end)))'
                """)
            guard outside == 0 else {
                throw LibreReverseShardBuilderError.integrity("frame outside shard interval")
            }
        case 1:
            // SQLCipher's integrity primitive walks the encrypted envelope once
            // and authenticates every persisted page HMAC. It detects damaged
            // or modified pages without SQLite's much costlier second pass that
            // cross-checks every index entry against its table row.
            if let violation = try cipherIntegrityViolation(database) {
                throw LibreReverseShardBuilderError.integrity(
                    "cipher integrity check failed: \(violation)"
                )
            }
        case 2:
            if let violation = try foreignKeyViolation(database) {
                throw LibreReverseShardBuilderError.integrity(
                    "foreign key check failed: \(violation)"
                )
            }
        default:
            let start = sql(databaseString(interval.start))
            let end = sql(databaseString(interval.end))
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM frame",
                source: "SELECT COUNT(*) FROM source.frame WHERE createdAt>='\(start)' AND createdAt<'\(end)'",
                name: "frame"
            )
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM node",
                source: """
                    SELECT COUNT(*) FROM source.node n JOIN source.frame f ON f.id=n.frameId
                     WHERE f.createdAt>='\(start)' AND f.createdAt<'\(end)'
                    """,
                name: "node"
            )
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM doc_segment",
                source: """
                    SELECT COUNT(*) FROM source.doc_segment d
                     WHERE d.frameId IN (
                       SELECT id FROM source.frame
                        WHERE createdAt>='\(start)' AND createdAt<'\(end)'
                     ) OR (d.frameId IS NULL AND d.segmentId IN (
                       SELECT id FROM source.segment
                        WHERE startDate>='\(start)' AND startDate<'\(end)'
                     ))
                    """,
                name: "document"
            )
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM audio",
                source: """
                    SELECT COUNT(*) FROM source.audio a JOIN source.segment s ON s.id=a.segmentId
                     WHERE s.startDate>='\(start)' AND s.startDate<'\(end)'
                    """,
                name: "audio"
            )
            try requireEqualCounts(
                database,
                destination: "SELECT COUNT(*) FROM transcript_word",
                source: """
                    SELECT COUNT(*) FROM source.transcript_word w
                    JOIN source.segment s ON s.id=w.segmentId
                     WHERE s.startDate>='\(start)' AND s.startDate<'\(end)'
                    """,
                name: "transcript"
            )
            let documentCount = try scalarInt64(database, "SELECT COUNT(*) FROM doc_segment")
            let searchCount = try scalarInt64(database, "SELECT COUNT(*) FROM searchRanking")
            guard documentCount == searchCount else {
                throw LibreReverseShardBuilderError.integrity(
                    "document/search mismatch \(documentCount) != \(searchCount)"
                )
            }
            let missingSearchDocument = try optionalScalarInt64(database, """
                SELECT docid FROM doc_segment
                EXCEPT SELECT rowid FROM searchRanking
                LIMIT 1
                """)
            let orphanedSearchDocument = try optionalScalarInt64(database, """
                SELECT rowid FROM searchRanking
                EXCEPT SELECT docid FROM doc_segment
                LIMIT 1
                """)
            guard missingSearchDocument == nil, orphanedSearchDocument == nil else {
                throw LibreReverseShardBuilderError.integrity("document/search ID mismatch")
            }
            try execute(database, """
                UPDATE shard_build_manifest SET state='complete' WHERE id=1;
                """)
            return true
        }
        try updatePhase(
            .verify,
            lastKey: step + 1,
            completedRows: step + 1,
            totalRows: 4,
            database: database
        )
        return false
    }

    private static func requireEqualCounts(
        _ database: OpaquePointer,
        destination: String,
        source: String,
        name: String
    ) throws {
        let destinationCount = try scalarInt64(database, destination)
        let sourceCount = try scalarInt64(database, source)
        guard destinationCount == sourceCount else {
            throw LibreReverseShardBuilderError.integrity(
                "\(name) source/destination mismatch \(sourceCount) != \(destinationCount)"
            )
        }
    }

    private static func currentPhase(_ database: OpaquePointer) throws -> LibreReverseShardBuildProgress.Phase {
        if try optionalText(database, "SELECT state FROM shard_build_manifest WHERE id=1") == "complete" {
            return .complete
        }
        for phase in LibreReverseShardBuildProgress.Phase.allCases where phase != .complete {
            let complete = try scalarInt64(database, """
                SELECT completed FROM shard_build_progress WHERE phase='\(phase.rawValue)'
                """)
            if complete == 0 { return phase }
        }
        return .complete
    }

    private static func progress(_ database: OpaquePointer) throws -> LibreReverseShardBuildProgress {
        let phase = try currentPhase(database)
        if phase == .complete {
            return .init(phase: .complete, completedRows: 1, totalRows: 1)
        }
        var statement: OpaquePointer?
        try prepare(database, """
            SELECT completedRows,totalRows FROM shard_build_progress WHERE phase=?
            """, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        bind(phase.rawValue, to: value, index: 1)
        guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
        return .init(
            phase: phase,
            completedRows: sqlite3_column_int64(value, 0),
            totalRows: sqlite3_column_int64(value, 1)
        )
    }

    private static func phaseLastKey(
        _ phase: LibreReverseShardBuildProgress.Phase,
        database: OpaquePointer
    ) throws -> Int64 {
        try scalarInt64(database, """
            SELECT lastKey FROM shard_build_progress WHERE phase='\(phase.rawValue)'
            """)
    }

    private static func completePhase(
        _ phase: LibreReverseShardBuildProgress.Phase,
        database: OpaquePointer
    ) throws {
        try execute(database, """
            UPDATE shard_build_progress
               SET completed=1,updatedAt=strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE phase='\(phase.rawValue)'
            """)
    }

    private static func updatePhase(
        _ phase: LibreReverseShardBuildProgress.Phase,
        lastKey: Int64,
        completedRows: Int64,
        totalRows: Int64,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        try prepare(database, """
            UPDATE shard_build_progress
               SET lastKey=?,completedRows=?,totalRows=?,
                   updatedAt=strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE phase=?
            """, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        sqlite3_bind_int64(value, 1, lastKey)
        sqlite3_bind_int64(value, 2, completedRows)
        sqlite3_bind_int64(value, 3, totalRows)
        bind(phase.rawValue, to: value, index: 4)
        try stepDone(value, database)
    }

    private static func seedPhases(_ database: OpaquePointer) throws {
        for phase in LibreReverseShardBuildProgress.Phase.allCases where phase != .complete {
            try execute(database, """
                INSERT OR IGNORE INTO shard_build_progress(phase,lastKey)
                VALUES('\(phase.rawValue)',\(phase == .search ? Int64.min : 0))
                """)
        }
    }

    private static func buildMatches(
        database: OpaquePointer,
        source: LibreReverseLibraryConfiguration,
        interval: LibreReverseShardInterval,
        sourceStats: (maxID: Int64, count: Int64)
    ) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(database, """
            SELECT intervalStart,intervalEnd,ordinal,sourcePath,
                   sourceFrameMax,sourceFrameCount
              FROM shard_build_manifest WHERE id=1
            """, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { return false }
        return string(value, column: 0) == databaseString(interval.start)
            && string(value, column: 1) == databaseString(interval.end)
            && sqlite3_column_int64(value, 2) == interval.ordinal
            && string(value, column: 3) == source.databaseURL.standardizedFileURL.path
            && sqlite3_column_int64(value, 4) == sourceStats.maxID
            && sqlite3_column_int64(value, 5) == sourceStats.count
    }

    private static func sourceFrameStats(
        _ source: LibreReverseLibraryConfiguration,
        interval: LibreReverseShardInterval
    ) throws -> (maxID: Int64, count: Int64) {
        try withDatabase(
            url: source.databaseURL,
            keyFileURL: source.keyFileURL,
            create: false
        ) { database in
            var statement: OpaquePointer?
            try prepare(database, """
                SELECT COALESCE(MAX(id),0),COUNT(*) FROM frame
                 WHERE createdAt>=? AND createdAt<?
                """, &statement)
            let value = try unwrap(statement, database)
            defer { sqlite3_finalize(value) }
            bind(databaseString(interval.start), to: value, index: 1)
            bind(databaseString(interval.end), to: value, index: 2)
            guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
            return (sqlite3_column_int64(value, 0), sqlite3_column_int64(value, 1))
        }
    }

    private static func attachSource(
        _ source: LibreReverseLibraryConfiguration,
        to database: OpaquePointer
    ) throws {
        let key = try Data(contentsOf: source.keyFileURL)
        let sourceURI = "file:\(source.databaseURL.standardizedFileURL.path)?mode=ro"
        var statement: OpaquePointer?
        try prepare(database, "ATTACH DATABASE ? AS source KEY ?", &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        bind(sourceURI, to: value, index: 1)
        bind(key, to: value, index: 2)
        try stepDone(value, database)
    }

    private static func nextKey(
        _ database: OpaquePointer,
        sql: String,
        strings: [String],
        lastKey: Int64,
        limit: Int
    ) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        var index: Int32 = 1
        for string in strings {
            bind(string, to: value, index: index)
            index += 1
        }
        sqlite3_bind_int64(value, index, lastKey)
        sqlite3_bind_int64(value, index + 1, Int64(limit))
        guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
        return optionalInt64(value, column: 0)
    }

    private static func transaction(
        _ database: OpaquePointer,
        operation: () throws -> Void
    ) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try operation()
            try execute(database, "COMMIT")
        } catch {
            try? execute(database, "ROLLBACK")
            throw error
        }
    }

    private static let shardSchemaSQL = """
    PRAGMA user_version=41;
    CREATE TABLE IF NOT EXISTS segment(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,bundleID TEXT,startDate TEXT NOT NULL,
      endDate TEXT NOT NULL,windowName TEXT,browserUrl TEXT,browserProfile TEXT,
      type INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS video(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,height INTEGER NOT NULL,width INTEGER NOT NULL,
      path TEXT NOT NULL DEFAULT '',fileSize INTEGER,frameRate REAL NOT NULL DEFAULT 0.0,
      uploadedAt TEXT,xid TEXT,processingState INTEGER NOT NULL DEFAULT 0,
      captureType TEXT,local INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS frame(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,createdAt TEXT NOT NULL,
      imageFileName TEXT NOT NULL,segmentId INTEGER REFERENCES segment(id),
      videoId INTEGER REFERENCES video(id),videoFrameIndex INTEGER,
      isStarred INTEGER NOT NULL DEFAULT 0,encodingStatus TEXT
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS searchRanking
      USING fts5(text,otherText,title,tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS search
      USING fts4(text,otherText,tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchOffsets
      USING fts4(text,otherText,tokenize=porter);
    CREATE TABLE IF NOT EXISTS doc_segment(
      docid INTEGER NOT NULL UNIQUE,segmentId INTEGER NOT NULL REFERENCES segment(id),
      frameId INTEGER REFERENCES frame(id)
    );
    CREATE TABLE IF NOT EXISTS node(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,frameId INTEGER NOT NULL REFERENCES frame(id),
      nodeOrder INTEGER NOT NULL,textOffset INTEGER NOT NULL,textLength INTEGER NOT NULL,
      leftX REAL NOT NULL,topY REAL NOT NULL,width REAL NOT NULL,height REAL NOT NULL,
      windowIndex INTEGER
    );
    CREATE TABLE IF NOT EXISTS audio(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,segmentId INTEGER NOT NULL REFERENCES segment(id),
      path TEXT NOT NULL,startTime TEXT NOT NULL,duration REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS transcript_word(
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,segmentId INTEGER NOT NULL REFERENCES segment(id),
      speechSource TEXT NOT NULL,word TEXT NOT NULL,timeOffset INTEGER NOT NULL,
      fullTextOffset INTEGER,duration INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS shard_build_manifest(
      id INTEGER PRIMARY KEY CHECK(id=1),intervalStart TEXT NOT NULL,intervalEnd TEXT NOT NULL,
      ordinal INTEGER NOT NULL,sourcePath TEXT NOT NULL,sourceFrameMax INTEGER NOT NULL,
      sourceFrameCount INTEGER NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('building','complete'))
    );
    CREATE TABLE IF NOT EXISTS shard_build_progress(
      phase TEXT PRIMARY KEY NOT NULL,lastKey INTEGER NOT NULL DEFAULT 0,
      completedRows INTEGER NOT NULL DEFAULT 0,totalRows INTEGER NOT NULL DEFAULT 0,
      completed INTEGER NOT NULL DEFAULT 0,updatedAt TEXT
    );
    """

    private static let shardIndexes = [
        "CREATE INDEX IF NOT EXISTS index_frame_on_createdat ON frame(createdAt)",
        "CREATE INDEX IF NOT EXISTS index_frame_on_segmentid_createdat ON frame(segmentId,createdAt)",
        "CREATE INDEX IF NOT EXISTS index_frame_on_videoid ON frame(videoId)",
        "CREATE INDEX IF NOT EXISTS index_frame_on_isstarred_createdat ON frame(isStarred,createdAt)",
        "CREATE INDEX IF NOT EXISTS index_frame_on_encodingstatus_createdat ON frame(encodingStatus,createdAt)",
        "CREATE INDEX IF NOT EXISTS index_segment_on_starttime ON segment(startDate)",
        "CREATE INDEX IF NOT EXISTS index_segment_on_endtime ON segment(endDate)",
        "CREATE INDEX IF NOT EXISTS index_segment_on_appid ON segment(bundleID)",
        "CREATE INDEX IF NOT EXISTS index_node_on_frameid ON node(frameId)",
        "CREATE INDEX IF NOT EXISTS index_doc_segment_on_frameid_docid ON doc_segment(frameId,docid)",
        "CREATE INDEX IF NOT EXISTS index_doc_segment_on_segmentid_docid ON doc_segment(segmentId,docid)",
        "CREATE INDEX IF NOT EXISTS index_transcript_word_on_segmentid_fulltextoffset ON transcript_word(segmentId,fullTextOffset)",
    ]

    private static func withDatabase<T>(
        url: URL,
        keyFileURL: URL,
        create: Bool,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try LibreReverseLibraryKey.validate(keyFileURL)
        let key = try Data(contentsOf: keyFileURL)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage) ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw LibreReverseShardBuilderError.unableToOpenDatabase(message)
        }
        defer { sqlite3_close(database) }
        let keyStatus = key.withUnsafeBytes {
            sqlite3_key(database, $0.baseAddress, Int32($0.count))
        }
        guard keyStatus == SQLITE_OK else {
            throw LibreReverseShardBuilderError.unableToApplyKey(keyStatus)
        }
        try execute(database, "PRAGMA busy_timeout=5000")
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

    private static func stepDone(_ statement: OpaquePointer, _ database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage(database)
            sqlite3_free(message)
            throw LibreReverseShardBuilderError.sqlite(text)
        }
    }

    private static func scalarInt64(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        guard sqlite3_step(value) == SQLITE_ROW else { throw sqliteError(database) }
        if sqlite3_column_type(value, 0) == SQLITE_TEXT,
           let text = string(value, column: 0), let number = Int64(text) {
            return number
        }
        return sqlite3_column_int64(value, 0)
    }

    private static func optionalScalarInt64(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> Int64? {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        let status = sqlite3_step(value)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteError(database) }
        return optionalInt64(value, column: 0)
    }

    private static func cipherIntegrityViolation(_ database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        try prepare(database, "PRAGMA cipher_integrity_check", &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        let status = sqlite3_step(value)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteError(database) }
        return string(value, column: 0) ?? "unknown page authentication error"
    }

    private static func optionalText(_ database: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        try prepare(database, sql, &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        let status = sqlite3_step(value)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteError(database) }
        return string(value, column: 0)
    }

    private static func foreignKeyViolation(_ database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        try prepare(database, "PRAGMA foreign_key_check", &statement)
        let value = try unwrap(statement, database)
        defer { sqlite3_finalize(value) }
        let status = sqlite3_step(value)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteError(database) }
        return "\(string(value, column: 0) ?? "?") row \(sqlite3_column_int64(value, 1)) -> \(string(value, column: 2) ?? "?")"
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

    private static func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private static func optionalInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, column)
    }

    private static func databaseString(_ date: Date) -> String {
        databaseDateFormatter.string(from: date)
    }

    private static let databaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Source timestamps such as `frame.createdAt` and `segment.startDate`
        // use UTC strings without a zone suffix. Keeping that representation
        // makes half-open boundary comparisons lexically correct in SQLite.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func sqliteError(_ database: OpaquePointer) -> LibreReverseShardBuilderError {
        .sqlite(errorMessage(database))
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }
}
#endif
