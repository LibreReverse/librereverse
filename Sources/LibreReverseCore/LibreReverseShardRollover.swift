#if os(macOS)
import Darwin
import Foundation

public struct LibreReverseShardRolloverResult: Equatable, Sendable {
    public let previousActiveOrdinal: Int64
    public let activeOrdinal: Int64
    public let sealedShards: [LibreReverseShardManifest]
    public let primary: LibreReversePrimaryManifest
}

public enum LibreReverseShardRolloverError: Error, Equatable {
    case databaseIsNotSharded
    case targetPrecedesActive
    case pendingMeetingTranscriptions([String])
    case unresolvedMeetingTranscriptionJobs([String])
    case pendingSparseFrameRecovery(Int)
    case atomicSwapFailed(Int32)
    case replacementValidationFailed
}

extension LibreReverseShardRolloverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseIsNotSharded: "The library is not sharded"
        case .targetPrecedesActive: "The rollover target precedes the active shard"
        case .pendingMeetingTranscriptions(let xids):
            "Shard rollover is waiting for \(xids.count) meeting transcript(s)"
        case .unresolvedMeetingTranscriptionJobs(let names):
            "Shard rollover found \(names.count) unresolved transcription queue file(s)"
        case .pendingSparseFrameRecovery(let count):
            "Shard rollover is waiting to recover \(count) sparse frame(s)"
        case .atomicSwapFailed(let code): "The primary database swap failed (errno \(code))"
        case .replacementValidationFailed: "The replacement primary failed validation"
        }
    }

    /// Capture resumes immediately after any rollover failure; this controls
    /// only when maintenance should finalize the new sparse chunk and retry.
    /// Unresolved queue artifacts need repair rather than rapid polling, while
    /// ordinary failures and active transcription receive a prompt retry.
    public var retryDelay: TimeInterval {
        switch self {
        case .unresolvedMeetingTranscriptionJobs: 60 * 60
        default: 15 * 60
        }
    }
}

/// Exact-boundary maintenance for the compact writable primary.
///
/// Capture is paused by the caller before entering this operation. Every
/// closed interval is first sealed into an independently verified SQLCipher
/// file. A replacement primary is then built and verified off to the side;
/// the only visibility change is one atomic filename swap. A crash before the
/// swap leaves the old primary authoritative, while a crash after it leaves
/// the new primary authoritative plus a harmless retired file.
public enum LibreReverseShardRollover {
    public static func isRequired(
        at date: Date,
        configuration: LibreReverseLibraryConfiguration
    ) throws -> Bool {
        try LibreReverseShardStore.initialize(configuration)
        guard
            let active = try LibreReverseShardStore.activeOrdinal(
                configuration: configuration
            )
        else { return false }
        let epoch = try LibreReverseShardStore.epochStart(configuration: configuration)
        return LibreReverseShardInterval.ordinal(containing: date, epochStart: epoch) > active
    }

    @discardableResult
    public static func performIfNeeded(
        at date: Date,
        configuration: LibreReverseLibraryConfiguration,
        batchSize: Int = LibreReverseShardBuilder.defaultBatchSize,
        transcriptionQueue: LibreReverseMeetingTranscriptionQueue? = nil
    ) throws -> LibreReverseShardRolloverResult? {
        let queue =
            transcriptionQueue
            ?? LibreReverseMeetingTranscriptionQueue(
                root: configuration.databaseURL.deletingLastPathComponent()
                    .appendingPathComponent("MeetingTranscriptionQueue", isDirectory: true)
            )
        return try queue.withExclusiveAccess {
            try performIfNeededAssumingExclusiveQueueAccess(
                at: date,
                configuration: configuration,
                batchSize: batchSize,
                transcriptionQueue: queue
            )
        }
    }

    private static func performIfNeededAssumingExclusiveQueueAccess(
        at date: Date,
        configuration: LibreReverseLibraryConfiguration,
        batchSize: Int,
        transcriptionQueue: LibreReverseMeetingTranscriptionQueue
    ) throws -> LibreReverseShardRolloverResult? {
        try LibreReverseShardStore.initialize(configuration)
        guard
            let previousActive = try LibreReverseShardStore.activeOrdinal(
                configuration: configuration
            )
        else { return nil }
        let epoch = try LibreReverseShardStore.epochStart(configuration: configuration)
        let target = LibreReverseShardInterval.ordinal(containing: date, epochStart: epoch)
        guard target >= previousActive else {
            throw LibreReverseShardRolloverError.targetPrecedesActive
        }

        let replacementURL = configuration.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("library.sqlite3.rollover")
        guard target > previousActive else {
            // This is the retired pre-swap primary if a prior rollover was
            // interrupted after its atomic commit.
            try? FileManager.default.removeItem(at: replacementURL)
            return nil
        }

        let activeInterval = LibreReverseShardInterval(ordinal: target, epochStart: epoch)
        let strandedFrames = try LibreReverseLibraryStore.loadRecoverableFrames(
            configuration: configuration
        ).filter { !activeInterval.contains($0.createdAt) }
        guard strandedFrames.isEmpty else {
            throw LibreReverseShardRolloverError.pendingSparseFrameRecovery(
                strandedFrames.count
            )
        }
        let repair = try transcriptionQueue.repairCorruptJobsAssumingExclusiveAccess(
            configuration: configuration
        )
        guard repair.unresolvedFileNames.isEmpty else {
            throw LibreReverseShardRolloverError.unresolvedMeetingTranscriptionJobs(
                repair.unresolvedFileNames
            )
        }
        var blockingXIDs: [String] = []
        for job in try transcriptionQueue.pending() {
            guard
                let publication = try LibreReverseLibraryStore.publishedMeeting(
                    xid: job.publicationXID,
                    configuration: configuration
                )
            else {
                throw LibreReverseShardRolloverError.unresolvedMeetingTranscriptionJobs([
                    "\(job.publicationXID).json"
                ])
            }
            if !activeInterval.contains(publication.startedAt) {
                blockingXIDs.append(job.publicationXID)
            }
        }
        guard blockingXIDs.isEmpty else {
            throw LibreReverseShardRolloverError.pendingMeetingTranscriptions(
                blockingXIDs.sorted()
            )
        }

        let shardRoot = configuration.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Shards", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shardRoot,
            withIntermediateDirectories: true
        )
        var entries: [LibreReverseShardCatalogEntry] = []
        var manifests: [LibreReverseShardManifest] = []
        for ordinal in previousActive..<target {
            let interval = LibreReverseShardInterval(ordinal: ordinal, epochStart: epoch)
            let finalURL = shardRoot.appendingPathComponent(interval.fileName)
            let buildingURL = shardRoot.appendingPathComponent(interval.fileName + ".building")
            if !FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try LibreReverseShardBuilder.buildToCompletion(
                    source: configuration,
                    destinationURL: buildingURL,
                    interval: interval,
                    batchSize: batchSize
                )
                try FileManager.default.moveItem(at: buildingURL, to: finalURL)
            }
            let manifest = try LibreReverseShardBuilder.seal(
                source: configuration,
                destinationURL: finalURL,
                interval: interval
            )
            manifests.append(manifest)
            entries.append(
                .init(
                    manifest: manifest,
                    relativePath: "Shards/\(interval.fileName)"
                ))
        }

        // A pre-swap crash may leave a complete or partial candidate. It was
        // never authoritative, so rebuilding it is deterministic and safe.
        try? FileManager.default.removeItem(at: replacementURL)
        let primary = try LibreReverseShardBuilder.buildReplacementPrimary(
            source: configuration,
            destinationURL: replacementURL,
            activeInterval: activeInterval,
            sealedShards: entries
        )
        _ = try LibreReverseShardBuilder.prepareSourceForCutover(configuration)
        let swapStatus = configuration.databaseURL.path.withCString { sourcePath in
            replacementURL.path.withCString { replacementPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    replacementPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard swapStatus == 0 else {
            throw LibreReverseShardRolloverError.atomicSwapFailed(errno)
        }

        try LibreReverseLibraryStore.initialize(configuration)
        guard try LibreReverseShardStore.activeOrdinal(configuration: configuration) == target else {
            throw LibreReverseShardRolloverError.replacementValidationFailed
        }
        try? FileManager.default.removeItem(at: replacementURL)
        return .init(
            previousActiveOrdinal: previousActive,
            activeOrdinal: target,
            sealedShards: manifests,
            primary: primary
        )
    }
}
#endif
