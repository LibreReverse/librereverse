#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

public enum CloneFrameEncodingStatus: String, Codable, Equatable {
    case deferred
    case failed
    case pending
    case success
}

public struct LibreReverseCaptureContext: Codable, Equatable, Sendable {
    public let bundleID: String?
    public let windowName: String?
    public let browserURL: String?
    public let browserProfile: String?

    public init(
        bundleID: String?,
        windowName: String?,
        browserURL: String? = nil,
        browserProfile: String? = nil
    ) {
        self.bundleID = bundleID
        self.windowName = windowName
        self.browserURL = browserURL
        self.browserProfile = browserProfile
    }
}

/// Only frames whose encoding or commit can still need recovery belong in memory.
/// Stable database IDs remain valid while earlier chunks are removed during replay.
struct CanonicalRecorderMetadata {
    struct Frame {
        let canonicalFrameID: Int64
        let createdAt: Date
        let imageFileName: String
        var videoFrameIndex: Int?
    }
    private var frames: [Int64: Frame] = [:]
    var count: Int { frames.count }
    var orderedFrameIDs: [Int64] {
        frames.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.canonicalFrameID < $1.canonicalFrameID : $0.createdAt < $1.createdAt
        }.map(\.canonicalFrameID)
    }
    subscript(_ id: Int64) -> Frame? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
    mutating func removeCommitted(_ ids: [Int64]) {
        for id in ids { frames.removeValue(forKey: id) }
    }
}

public enum ScreenRecordingSessionError: Error {
    case recoveryRequired
    case invalidDimensions
    case unableToWriteImage
    case libraryMediaRootMismatch
    case uncommittedMediaCleanupFailed(String)
}

public struct ScreenRecordingIngestResult {
    public let decision: ScreenDifferenceDecision
    public let admittedFrame: LibreReverseAdmittedFrame?
}

/// End-to-end local capture/difference/chunk writer. Accepted screenshots use
/// chunk-local sequential frame numbers regardless of capture spacing.
/// Rejected screenshots do not consume video frame numbers.
@MainActor
public final class ScreenRecordingSession {
    public let outputDirectory: URL
    public private(set) var requiresRecovery = false
    private let differ = ScreenDifferenceWorker()
    private let pngEncoder = CapturePNGEncoder()
    private var writer: FrameVideoWriter?
    private var chunkStart: Date?
    private var chunkDimensions: (Int, Int)?
    private var chunkSamples = 0
    private var chunkFrameIDs: [Int64] = []
    private var metadata = CanonicalRecorderMetadata()
    var retainedFrameCount: Int { metadata.count }
    private let databaseSession: LibreReverseLibraryWriteSession
    private let libraryConfiguration: LibreReverseLibraryConfiguration
    private let onChunkFinalized: (@Sendable (Int64) -> Void)?
    private let captureSessionID = UUID().uuidString

    public init(
        outputDirectory: URL,
        libraryConfiguration: LibreReverseLibraryConfiguration,
        onChunkFinalized: (@Sendable (Int64) -> Void)? = nil
    ) throws {
        if libraryConfiguration.mediaRoot.standardizedFileURL
                != outputDirectory.standardizedFileURL
        {
            throw ScreenRecordingSessionError.libraryMediaRootMismatch
        }
        self.outputDirectory = outputDirectory
        self.libraryConfiguration = libraryConfiguration
        databaseSession = LibreReverseLibraryWriteSession(configuration: libraryConfiguration)
        self.onChunkFinalized = onChunkFinalized
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at:
                outputDirectory
                .appendingPathComponent("temp", isDirectory: true)
                .appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
        for frame in try LibreReverseLibraryStore.loadRecoverableFrames(
            configuration: libraryConfiguration, session: databaseSession
        ) {
            metadata[frame.id] = .init(canonicalFrameID: frame.id,
                createdAt: frame.createdAt, imageFileName: frame.imageFileName)
        }
    }

    /// Recover interrupted encoding work at launch. Durable source PNGs let
    /// pending and failed records return to deferred state for fresh dense batches.
    @discardableResult
    public func recoverDeferredFrames() async throws -> Int {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("CaptureIngest", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureIngest", interval) }
        guard !requiresRecovery else { throw ScreenRecordingSessionError.recoveryRequired }
        do { return try await recoverFrames() }
        catch {
            requiresRecovery = true
            writer?.abort(with: error)
            databaseSession.close()
            throw error
        }
    }

    private func recoverFrames() async throws -> Int {
        guard writer == nil, chunkFrameIDs.isEmpty else { return 0 }
        let candidates = metadata.orderedFrameIDs
        let finalDate = candidates.last.flatMap { metadata[$0]?.createdAt }
        var recovered = 0
        for recordID in candidates {
            guard let record = metadata[recordID] else { continue }
            let imageURL =
                outputDirectory
                .appendingPathComponent("temp", isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent(record.imageFileName)
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                try updateCanonicalFrameStatus(for: record, to: .failed)
                continue
            }
            try updateCanonicalFrameStatus(for: record, to: .deferred)
            if chunkDimensions?.0 != image.width || chunkDimensions?.1 != image.height {
                try await closeChunk(at: record.createdAt)
            }
            if writer == nil {
                try openChunk(width: image.width, height: image.height, at: record.createdAt)
            }
            let frameNumber = Int64(chunkSamples)
            do {
                _ = try writer?.write(frameNumber: frameNumber, image: image)
            } catch {
                requiresRecovery = true
                writer?.abort(with: error)
                try? updateCanonicalFrameStatus(for: record, to: .failed)
                throw error
            }
            try updateCanonicalFrameStatus(for: record, to: .pending)
            metadata[recordID]?.videoFrameIndex = Int(frameNumber)
            chunkFrameIDs.append(recordID)
            chunkSamples += 1
            recovered += 1
            if chunkSamples >= RecordingContract.maximumFramesPerVideo {
                try await closeChunk(at: record.createdAt)
            }
        }
        if let finalDate {
            try await closeChunk(at: finalDate)
        }
        return recovered
    }

    @discardableResult
    public func ingest(
        _ frame: CapturedScreenFrame,
        at date: Date = Date(),
        context: LibreReverseCaptureContext? = nil
    ) async throws -> ScreenDifferenceDecision {
        try await ingestWithAdmission(frame, at: date, context: context).decision
    }

    /// Product-facing form which carries the exact durable Segment identity
    /// created before encoding. The canonical recording update hands a full
    /// Segment into SegmentList; callers must not synthesize a separate ID.
    public func ingestWithAdmission(
        _ frame: CapturedScreenFrame,
        at date: Date = Date(),
        context: LibreReverseCaptureContext? = nil
    ) async throws -> ScreenRecordingIngestResult {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("CaptureIngest", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureIngest", interval) }
        guard !requiresRecovery else { throw ScreenRecordingSessionError.recoveryRequired }
        do {
            try writer?.checkCanWrite()
            return try await ingestFrame(frame, at: date, context: context)
        } catch {
            requiresRecovery = true
            writer?.abort(with: error)
            databaseSession.close()
            throw error
        }
    }

    private func ingestFrame(_ frame: CapturedScreenFrame, at date: Date,
                             context: LibreReverseCaptureContext?) async throws -> ScreenRecordingIngestResult {
        let decision = try await differ.process(frame)
        // A quiet screen may never reach the 150 changed-frame boundary. Close
        // its current file on the five-minute maintenance cadence so a verified
        // Drive checkpoint advances even while very little changes.
        if writer != nil,
            let chunkStart,
            date.timeIntervalSince(chunkStart)
                >= RecordingContract.deferredWriteIntervalSeconds
        {
            try await closeChunk(at: date)
        }
        guard decision.admitted else {
            return ScreenRecordingIngestResult(decision: decision, admittedFrame: nil)
        }
        guard frame.image.width > 0, frame.image.height > 0 else {
            throw ScreenRecordingSessionError.invalidDimensions
        }
        if chunkDimensions?.0 != frame.image.width || chunkDimensions?.1 != frame.image.height {
            try await closeChunk(at: date)
        }
        let imageFileName = Self.temporaryFilename(for: date)
        let imageURL = outputDirectory
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(imageFileName)
        // Await durable recovery data before admission, without blocking UI.
        let pngEncoder = self.pngEncoder
        try await Task.detached(priority: .utility) {
            try autoreleasepool { try pngEncoder.write(frame, to: imageURL) }
        }.value
        let admitted = try LibreReverseLibraryStore.admitFrame(
            createdAt: date,
            imageFileName: imageFileName,
            context: context,
            captureSessionID: captureSessionID,
            configuration: libraryConfiguration, session: databaseSession
        )
        metadata[admitted.id] = .init(canonicalFrameID: admitted.id,
            createdAt: date, imageFileName: imageFileName)
        chunkFrameIDs.append(admitted.id)
        if writer == nil {
            try openChunk(width: frame.image.width, height: frame.image.height, at: date)
        }
        // Each AVAssetWriter session starts at zero and the controller supplies
        // dense batch-local indices, not wall-clock-derived capture positions.
        let frameNumber = Int64(chunkSamples)
        do {
            _ = try writer?.write(frameNumber: frameNumber, frame: frame)
        } catch {
            if let recordID = chunkFrameIDs.last,
                let record = metadata[recordID]
            {
                try? updateCanonicalFrameStatus(for: record, to: .failed)
            }
            throw error
        }
        if let recordID = chunkFrameIDs.last {
            metadata[recordID]?.videoFrameIndex = Int(frameNumber)
            if let record = metadata[recordID] {
                try updateCanonicalFrameStatus(for: record, to: .pending)
            }
        }
        chunkSamples += 1
        if chunkSamples >= RecordingContract.maximumFramesPerVideo {
            try await closeChunk(at: date)
        }
        return ScreenRecordingIngestResult(decision: decision, admittedFrame: admitted)
    }

    public func finish(at date: Date = Date()) async throws {
        defer { databaseSession.close() }
        try await closeChunk(at: date)
    }

    private func openChunk(width: Int, height: Int, at date: Date) throws {
        let url = try VideoStorage.temporaryVideoURL(
            chunksDirectory: outputDirectory
        )
        writer = try FrameVideoWriter(outputURL: url, width: width, height: height)
        chunkStart = date
        chunkDimensions = (width, height)
        chunkSamples = 0
    }

    private func closeChunk(at date: Date) async throws {
        do { try await finalizeChunk(at: date) }
        catch {
            requiresRecovery = true
            writer?.abort(with: error)
            databaseSession.close()
            throw error
        }
    }

    private func finalizeChunk(at date: Date) async throws {
        guard let active = writer,
            let start = chunkStart,
            let dimensions = chunkDimensions
        else { return }
        let signposter = CaptureDiffInstrumentation.signposter
        let flush = signposter.beginInterval("VideoChunkFlush", id: signposter.makeSignpostID())
        signposter.emitEvent("ChunkFrames", "count: \(self.chunkSamples)")
        defer { signposter.endInterval("VideoChunkFlush", flush) }
        try await active.finish()
        let xid = XID.generate(at: start)
        let recordedPath = VideoStorage.relativePath(xid: xid, date: start)
        let storedURL = try VideoStorage.storeTemporaryVideo(
            at: active.outputURL,
            relativePath: recordedPath,
            chunksDirectory: outputDirectory
        )
        let frames = chunkFrameIDs.compactMap {
            recordID -> LibreReverseRecordedFrame? in
            guard let record = metadata[recordID],
                let videoFrameIndex = record.videoFrameIndex
            else { return nil }
            return LibreReverseRecordedFrame(
                frameID: record.canonicalFrameID,
                videoFrameIndex: videoFrameIndex
            )
        }.sorted { $0.videoFrameIndex < $1.videoFrameIndex }
        guard frames.count == chunkSamples else {
            throw LibreReverseLibraryStoreError.invalidFrameSequence
        }
        let videoID: Int64
        do {
            videoID = try LibreReverseLibraryStore.commitRecordedChunk(
                LibreReverseRecordedChunk(
                    relativeMediaPath: recordedPath,
                    xid: xid,
                    width: dimensions.0,
                    height: dimensions.1,
                    frameRate: Double(CaptureContract.nominalVideoFrameRate),
                    frames: frames
                ),
                configuration: libraryConfiguration, session: databaseSession
            )
        } catch {
            if let libraryError = error as? LibreReverseLibraryStoreError,
                case .transactionOutcomeUnknown = libraryError
            {
                // Deleting media after an indeterminate COMMIT could turn
                // a durable Video row into corruption. Preserve it for
                // explicit reconciliation instead.
                throw error
            }
            do {
                try FileManager.default.removeItem(at: storedURL)
            } catch let cleanupError {
                throw ScreenRecordingSessionError.uncommittedMediaCleanupFailed(
                    "commit failed (\(error)); cleanup failed (\(cleanupError))"
                )
            }
            throw error
        }
        // A successful SQL commit is the only point at which metadata can be
        // discarded. Commit-unknown and rollback paths above retain every PNG.
        let cleanup = signposter.beginInterval("ChunkRecoveryCleanup", id: signposter.makeSignpostID())
        defer { signposter.endInterval("ChunkRecoveryCleanup", cleanup) }
        let committedFrames = chunkFrameIDs.compactMap { metadata[$0] }
        metadata.removeCommitted(chunkFrameIDs)
        writer = nil
        chunkStart = nil
        chunkDimensions = nil
        chunkSamples = 0
        chunkFrameIDs = []
        onChunkFinalized?(videoID)
        let imageRoot = outputDirectory.appendingPathComponent("temp/images", isDirectory: true)
        for record in committedFrames {
            // Cleanup failure must not leave an already-committed writer active.
            // Keeping a recovery PNG is preferable to replaying its durable frame.
            if (try? LibreReverseLibraryStore.canRemoveSourceImage(
                frameID: record.canonicalFrameID, configuration: libraryConfiguration, session: databaseSession
            )) == true {
                try? FileManager.default.removeItem(
                    at: imageRoot.appendingPathComponent(record.imageFileName))
            }
        }
    }

    private func updateCanonicalFrameStatus(
        for record: CanonicalRecorderMetadata.Frame,
        to status: CloneFrameEncodingStatus
    ) throws {
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: record.canonicalFrameID,
            status: status,
            configuration: libraryConfiguration, session: databaseSession
        )
    }

    private static func temporaryFilename(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        try CapturePNGEncoder.writeImageIO(image, to: url)
    }
}

#endif
