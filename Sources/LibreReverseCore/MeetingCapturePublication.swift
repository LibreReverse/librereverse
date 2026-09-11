#if os(macOS)
import AVFoundation
import Foundation

public enum LibreReverseMeetingCapturePublicationError: Error, Equatable {
    case unsupportedManifestSchemaVersion(Int)
    case captureNotCompleted(HighFidelityMeetingCaptureState)
    case writerNotCompleted(String)
    case captureReportedError(String)
    case outputPathMismatch(expected: String, actual: String)
    case missingStagedMedia(String)
    case missingPublicationXID
    case missingManifestPublicationXID
    case invalidPublicationXID(String)
    case publicationXIDMismatch(expected: String, actual: String)
    case invalidManifestField(String)
    case invalidDuration(TimeInterval)
    case destinationAlreadyExists(String)
    case unsupportedMediaFileType(String)
    case missingOutputIntegrity(String)
    case outputIntegrityMismatch(
        path: String,
        expectedByteCount: Int64,
        actualByteCount: Int64,
        expectedSHA256: String,
        actualSHA256: String
    )
}

extension LibreReverseMeetingCapturePublicationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedManifestSchemaVersion(let version):
            "Meeting capture manifest schema is unsupported: \(version)"
        case .captureNotCompleted(let state):
            "Meeting capture was not completed (state: \(state.rawValue))"
        case .writerNotCompleted(let status):
            "Meeting writer was not completed (status: \(status))"
        case .captureReportedError(let message):
            "Meeting capture reported an error: \(message)"
        case .outputPathMismatch(let expected, let actual):
            "Meeting output path mismatch: expected \(expected), found \(actual)"
        case .missingStagedMedia(let path):
            "Meeting staging media is missing: \(path)"
        case .missingPublicationXID:
            "Meeting publication is missing its durable recovery XID"
        case .missingManifestPublicationXID:
            "Meeting manifest is missing its durable recovery XID"
        case .invalidPublicationXID(let xid):
            "Meeting publication XID is invalid: \(xid)"
        case .publicationXIDMismatch(let expected, let actual):
            "Meeting publication XID mismatch: expected \(expected), found \(actual)"
        case .invalidManifestField(let field):
            "Meeting capture manifest has an invalid \(field)"
        case .invalidDuration(let duration):
            "Meeting capture duration is invalid: \(duration)"
        case .destinationAlreadyExists(let path):
            "Meeting destination already exists: \(path)"
        case .unsupportedMediaFileType(let path):
            "Meeting media is not a non-symlink regular file: \(path)"
        case .missingOutputIntegrity(let path):
            "Meeting media has no durable integrity evidence: \(path)"
        case .outputIntegrityMismatch(
            let path,
            let expectedByteCount,
            let actualByteCount,
            let expectedSHA256,
            let actualSHA256
        ):
            "Meeting media integrity mismatch at \(path): expected \(expectedByteCount) bytes / \(expectedSHA256), found \(actualByteCount) bytes / \(actualSHA256)"
        }
    }
}

public enum LibreReverseMeetingCaptureJournalError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case checkpointSchemaMismatch(schemaVersion: Int, hasCheckpoint: Bool)
    case invalidPublicationXID(String)
    case invalidCreationDate
    case invalidCandidateField(String)
    case invalidCheckpointField(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Meeting capture journal schema is unsupported: \(version)"
        case .checkpointSchemaMismatch(let version, let hasCheckpoint):
            "Meeting capture journal schema \(version) hasCheckpoint=\(hasCheckpoint)"
        case .invalidPublicationXID(let xid):
            "Meeting capture journal has an invalid publication XID: \(xid)"
        case .invalidCreationDate:
            "Meeting capture journal has an invalid creation date"
        case .invalidCandidateField(let field):
            "Meeting capture journal has an invalid candidate \(field)"
        case .invalidCheckpointField(let field):
            "Meeting capture recovery checkpoint has an invalid \(field)"
        }
    }
}

public enum LibreReverseMeetingRecoveryFailureDisposition: Equatable, Sendable {
    case retry
    case reject
}

public enum LibreReverseMeetingRecoveryFailureClassifier {
    public static func disposition(
        for error: Error
    ) -> LibreReverseMeetingRecoveryFailureDisposition {
        if error is LibreReverseMeetingCapturePublicationError
            || error is LibreReverseMeetingCaptureJournalError
            || error is LibreReverseMeetingTranscriptionQueueError
        {
            return .reject
        }
        if let libraryError = error as? LibreReverseLibraryStoreError,
            case .invalidMeeting = libraryError
        {
            return .reject
        }
        return .retry
    }
}

public struct LibreReverseFinalizedMeetingCapture: Sendable {
    public let stagingMediaURL: URL
    public let manifest: HighFidelityMeetingCaptureManifest
    public let candidate: LibreReverseMeetingCandidate
    public let transcript: MeetingTranscriptionResult?
    public let publicationXID: String?

    public init(
        stagingMediaURL: URL,
        manifest: HighFidelityMeetingCaptureManifest,
        candidate: LibreReverseMeetingCandidate,
        transcript: MeetingTranscriptionResult? = nil,
        publicationXID: String? = nil
    ) {
        self.stagingMediaURL = stagingMediaURL
        self.manifest = manifest
        self.candidate = candidate
        self.transcript = transcript
        self.publicationXID = publicationXID
    }
}

public struct LibreReverseMeetingCaptureJournal: Codable, Equatable, Sendable {
    public static let fileName = "publication.json"
    public let schemaVersion: Int
    public let publicationXID: String
    public let candidate: LibreReverseMeetingCandidate
    public let createdAt: Date
    public let recoveryCheckpoint: LibreReverseMeetingCaptureRecoveryCheckpoint?

    public init(
        publicationXID: String,
        candidate: LibreReverseMeetingCandidate,
        createdAt: Date = Date(),
        recoveryCheckpoint: LibreReverseMeetingCaptureRecoveryCheckpoint? = nil
    ) {
        schemaVersion = recoveryCheckpoint == nil ? 1 : 2
        self.publicationXID = publicationXID
        self.candidate = candidate
        self.createdAt = createdAt
        self.recoveryCheckpoint = recoveryCheckpoint
    }

    public func checkpointed(
        _ checkpoint: LibreReverseMeetingCaptureRecoveryCheckpoint
    ) -> Self {
        .init(
            publicationXID: publicationXID,
            candidate: candidate,
            createdAt: createdAt,
            recoveryCheckpoint: checkpoint
        )
    }

    /// Metadata edits rewrite the same atomic journal and preserve the exact
    /// post-start recovery checkpoint. A hard exit therefore publishes the
    /// edited title rather than reverting to the originally detected window.
    public func updatingCandidate(_ candidate: LibreReverseMeetingCandidate) -> Self {
        .init(
            publicationXID: publicationXID,
            candidate: candidate,
            createdAt: createdAt,
            recoveryCheckpoint: recoveryCheckpoint
        )
    }

    public func write(to directory: URL) throws {
        try validateOwnership()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: directory.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    public static func read(from directory: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(
            Self.self,
            from: Data(contentsOf: directory.appendingPathComponent(fileName))
        )
        guard (1...2).contains(journal.schemaVersion) else {
            throw LibreReverseMeetingCaptureJournalError.unsupportedSchemaVersion(
                journal.schemaVersion
            )
        }
        let hasCheckpoint = journal.recoveryCheckpoint != nil
        guard (journal.schemaVersion == 2) == hasCheckpoint else {
            throw LibreReverseMeetingCaptureJournalError.checkpointSchemaMismatch(
                schemaVersion: journal.schemaVersion,
                hasCheckpoint: hasCheckpoint
            )
        }
        try journal.validateOwnership()
        return journal
    }

    /// The journal is the durable owner of media, canonical publication, queue
    /// work, and archive identity. Reject malformed ownership before bytes are
    /// persisted or replayed into any of those systems.
    public func validateOwnership() throws {
        guard XID.isValid(publicationXID) else {
            throw LibreReverseMeetingCaptureJournalError.invalidPublicationXID(
                publicationXID
            )
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibreReverseMeetingCaptureJournalError.invalidCreationDate
        }
        try candidate.validateForRecoveryJournal()
        try recoveryCheckpoint?.validate()
    }
}

extension LibreReverseMeetingCandidate {
    /// Candidates may omit process ownership, but must not contain combinations
    /// that the production, manual, or calendar constructors cannot produce.
    fileprivate func validateForRecoveryJournal() throws {
        switch source {
        case .manual:
            guard provider == .manual else {
                throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                    "manual source/provider"
                )
            }
        case .calendar:
            guard provider == .calendar else {
                throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                    "calendar source/provider"
                )
            }
        case .windowDetection:
            guard provider != .manual, provider != .calendar else {
                throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                    "window source/provider"
                )
            }
        }
        if let windowID, windowID == 0 {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField("window ID")
        }
        if let processIdentifier, processIdentifier <= 0 {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                "process identifier"
            )
        }
        if processIdentifier != nil, windowID == nil {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                "process without window"
            )
        }
        if let bundleIdentifier,
            bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                "bundle identifier"
            )
        }
        let hasCalendarEvent = calendarEventID != nil
        let hasCalendar = calendarID != nil
        guard hasCalendarEvent == hasCalendar else {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                "calendar identity"
            )
        }
        for (value, field) in [
            (calendarEventID, "calendar event ID"),
            (calendarID, "calendar ID"),
            (calendarSeriesID, "calendar series ID"),
        ] where value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(field)
        }
        if calendarSeriesID != nil, !hasCalendarEvent {
            throw LibreReverseMeetingCaptureJournalError.invalidCandidateField(
                "calendar series without event"
            )
        }
    }
}

/// Durable facts written immediately after ScreenCaptureKit enters its
/// recording state. A hard process exit cannot run `stop()`, so the normal
/// terminal manifest does not exist. These values are sufficient to validate
/// a self-finalized SCRecordingOutput MP4 and synthesize a provenance-marked
/// terminal manifest without guessing candidate or capture configuration.
public struct LibreReverseMeetingCaptureRecoveryCheckpoint:
    Codable, Equatable, Sendable
{
    public let startedAt: Date
    public let hostClockStartSeconds: Double
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let requestedFrameRate: Int
    public let expectedSourceFrameRate: Int
    public let capturesSystemAudio: Bool
    public let capturesMicrophone: Bool
    public let microphoneDeviceID: String?

    public init(
        startedAt: Date,
        hostClockStartSeconds: Double,
        displayID: UInt32,
        width: Int,
        height: Int,
        requestedFrameRate: Int,
        expectedSourceFrameRate: Int,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        microphoneDeviceID: String?
    ) {
        self.startedAt = startedAt
        self.hostClockStartSeconds = hostClockStartSeconds
        self.displayID = displayID
        self.width = width
        self.height = height
        self.requestedFrameRate = requestedFrameRate
        self.expectedSourceFrameRate = expectedSourceFrameRate
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
    }

    /// Journals are durable, externally mutable input after a crash. Reject
    /// impossible framework values before AVFoundation opens the staged MP4 or
    /// a completed manifest is synthesized from untrusted checkpoint fields.
    public func validate() throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField("start date")
        }
        guard hostClockStartSeconds.isFinite, hostClockStartSeconds >= 0 else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField("host clock")
        }
        guard displayID != 0 else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField("display ID")
        }
        guard width > 0, width <= Int(Int32.max / 2) else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField("width")
        }
        guard height > 0, height <= Int(Int32.max / 2) else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField("height")
        }
        guard requestedFrameRate > 0,
            requestedFrameRate <= HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
        else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField(
                "requested frame rate"
            )
        }
        guard expectedSourceFrameRate > 0,
            expectedSourceFrameRate
                <= HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
        else {
            throw LibreReverseMeetingCaptureJournalError.invalidCheckpointField(
                "expected source frame rate"
            )
        }
    }
}

public enum LibreReverseMeetingCrashRecoveryError: Error, Equatable {
    case missingCheckpoint
    case missingMedia(String)
    case unreadableMedia
    case invalidDuration(Double)
    case missingVideoTrack
    case missingAudioTrack
    case invalidVideoDimensions(width: Int, height: Int)
    case videoDimensionsMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case unsupportedMediaFileType(String)
    case sampleValidationFailed(String)
}

/// Recovers only crash-interrupted artifacts that macOS independently made
/// readable. In particular, this never attempts to repair MP4 atoms, truncate
/// bytes, or publish a file merely because it exists. AVFoundation must parse
/// the duration, declared tracks, dimensions, and at least one compressed
/// sample from every required media class before a completed manifest is made.
enum MeetingFinalizationRecoveryRetry {
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError || error is LibreReverseMeetingCaptureJournalError { return false }
        guard let error = error as? LibreReverseMeetingCrashRecoveryError else { return true }
        switch error {
        case .missingCheckpoint, .invalidVideoDimensions, .videoDimensionsMismatch, .unsupportedMediaFileType:
            return false
        case .missingMedia, .unreadableMedia, .invalidDuration, .missingVideoTrack,
             .missingAudioTrack, .sampleValidationFailed:
            return true
        }
    }

    static func run<Value>(
        delays: [TimeInterval] = [2, 4, 8, 16],
        operation: () async throws -> Value,
        wait: (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) async throws -> Value {
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            }
            catch {
                guard isRetryable(error), attempt < delays.count else { throw error }
                try await wait(delays[attempt])
            }
        }
        preconditionFailure("Retry loop must return or throw")
    }
}

public enum LibreReverseMeetingCrashRecovery {
    public static let finalizationReason = "processCrashRecovered"

    /// A timed-out native writer can finalize after its stop callback deadline.
    /// Retry only a bounded number of probes; never delete or relax validation
    /// of staged media when the writer still cannot produce a valid artifact.
    public static func recoverFinalizingManifest(
        journal: LibreReverseMeetingCaptureJournal,
        directory: URL,
        capturedDuration: TimeInterval,
        timestamps: MeetingCaptureTimestampLedger
    ) async throws -> HighFidelityMeetingCaptureManifest {
        try await MeetingFinalizationRecoveryRetry.run(operation: {
            try await recoverManifest(journal: journal, directory: directory,
                finalizationReason: "recordingCompletionRecovered",
                capturedDuration: capturedDuration, timestamps: timestamps)
        })
    }

    public static func recoverManifest(
        journal: LibreReverseMeetingCaptureJournal,
        directory: URL,
        fileManager: FileManager = .default,
        finalizationReason: String = LibreReverseMeetingCrashRecovery.finalizationReason,
        capturedDuration: TimeInterval? = nil,
        timestamps: MeetingCaptureTimestampLedger? = nil
    ) async throws -> HighFidelityMeetingCaptureManifest {
        guard let checkpoint = journal.recoveryCheckpoint else {
            throw LibreReverseMeetingCrashRecoveryError.missingCheckpoint
        }
        try journal.validateOwnership()
        let mediaURL = directory.appendingPathComponent("meeting.mp4")
            .standardizedFileURL
        guard fileManager.fileExists(atPath: mediaURL.path) else {
            throw LibreReverseMeetingCrashRecoveryError.missingMedia(mediaURL.path)
        }

        do {
            let mediaValues = try mediaURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard mediaValues.isRegularFile == true,
                mediaValues.isSymbolicLink != true
            else {
                throw LibreReverseMeetingCrashRecoveryError.unsupportedMediaFileType(
                    mediaURL.path
                )
            }
            _ = await MeetingSpeechCapture.enhanceIfReady(movie: mediaURL)
            _ = try await MeetingVideoCompression.optimizeFinalizedStagingMovie(at: mediaURL)
            let asset = AVURLAsset(url: mediaURL)
            let isReadable = try await asset.load(.isReadable)
            let isPlayable = try await asset.load(.isPlayable)
            let hasProtectedContent = try await asset.load(.hasProtectedContent)
            guard isReadable, isPlayable, !hasProtectedContent else {
                throw LibreReverseMeetingCrashRecoveryError.unreadableMedia
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw LibreReverseMeetingCrashRecoveryError.invalidDuration(duration)
            }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw LibreReverseMeetingCrashRecoveryError.missingVideoTrack
            }
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            guard width > 0, height > 0 else {
                throw LibreReverseMeetingCrashRecoveryError.invalidVideoDimensions(
                    width: width,
                    height: height
                )
            }
            guard width == checkpoint.width, height == checkpoint.height else {
                throw LibreReverseMeetingCrashRecoveryError.videoDimensionsMismatch(
                    expectedWidth: checkpoint.width,
                    expectedHeight: checkpoint.height,
                    actualWidth: width,
                    actualHeight: height
                )
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if checkpoint.capturesSystemAudio || checkpoint.capturesMicrophone,
                audioTracks.isEmpty
            {
                throw LibreReverseMeetingCrashRecoveryError.missingAudioTrack
            }
            try validateFirstSamples(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTracks.first
            )
            if let capturedDuration {
                _ = try await HighFidelityMeetingCaptureMediaInspector.inspect(
                    url: mediaURL, expectedWidth: width, expectedHeight: height,
                    requiresAudio: checkpoint.capturesSystemAudio || checkpoint.capturesMicrophone,
                    capturedDuration: capturedDuration)
            }
            let outputIntegrity = try ArchiveIntegrityEngine.hash(file: mediaURL)
            let mediaEvidence = HighFidelityMeetingCaptureMediaEvidence(
                durationSeconds: duration,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                width: width,
                height: height,
                videoHasReadableSample: true,
                audioHasReadableSample: !audioTracks.isEmpty
            )

            return HighFidelityMeetingCaptureManifest(
                schemaVersion: 6,
                state: .completed,
                finalizationReason: finalizationReason,
                outputPath: mediaURL.path,
                displayID: checkpoint.displayID,
                width: width,
                height: height,
                requestedFrameRate: checkpoint.requestedFrameRate,
                expectedSourceFrameRate: checkpoint.expectedSourceFrameRate,
                capturesSystemAudio: checkpoint.capturesSystemAudio,
                capturesMicrophone: checkpoint.capturesMicrophone,
                microphoneDeviceID: checkpoint.microphoneDeviceID,
                startedAt: checkpoint.startedAt,
                finishedAt: checkpoint.startedAt.addingTimeInterval(duration),
                hostClockStartSeconds: checkpoint.hostClockStartSeconds,
                writerStatus: "completed",
                writerError: nil,
                streamError: nil,
                timestamps: timestamps ?? .init(frameRate: checkpoint.expectedSourceFrameRate),
                outputByteCount: outputIntegrity.byteCount,
                outputSHA256: outputIntegrity.sha256,
                publicationXID: journal.publicationXID,
                mediaEvidence: mediaEvidence
            )
        } catch let error as LibreReverseMeetingCrashRecoveryError {
            throw error
        } catch {
            throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                error.localizedDescription
            )
        }
    }

    private static func validateFirstSamples(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?
    ) throws {
        do {
            let reader = try AVAssetReader(asset: asset)
            let videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: nil
            )
            guard reader.canAdd(videoOutput) else {
                throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                    "video reader output is unsupported"
                )
            }
            reader.add(videoOutput)
            var audioOutput: AVAssetReaderTrackOutput?
            if let audioTrack {
                let output = AVAssetReaderTrackOutput(
                    track: audioTrack,
                    outputSettings: nil
                )
                guard reader.canAdd(output) else {
                    throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                        "audio reader output is unsupported"
                    )
                }
                reader.add(output)
                audioOutput = output
            }
            guard reader.startReading(), videoOutput.copyNextSampleBuffer() != nil else {
                throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                    reader.error?.localizedDescription ?? "video has no readable sample"
                )
            }
            if let audioOutput, audioOutput.copyNextSampleBuffer() == nil {
                throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                    reader.error?.localizedDescription ?? "audio has no readable sample"
                )
            }
            reader.cancelReading()
        } catch let error as LibreReverseMeetingCrashRecoveryError {
            throw error
        } catch {
            throw LibreReverseMeetingCrashRecoveryError.sampleValidationFailed(
                error.localizedDescription
            )
        }
    }
}

/// Publishes a dense capture artifact into the canonical library graph.
/// Reject failed or incomplete manifests while media remains staged, then
/// move the completed file to its yyyyMM/dd/XID path and commit the
/// segment, video, audio, transcript, and archive records in one transaction.
/// If publication fails, reverse the move so retry finds the staging artifact.
public enum LibreReverseMeetingCaptureFinalizer {
    public static func publish(
        _ capture: LibreReverseFinalizedMeetingCapture,
        configuration: LibreReverseLibraryConfiguration,
        clock: LegacyTranscriptClock = .rewind15607,
        fileManager: FileManager = .default
    ) throws -> LibreReversePublishedMeeting {
        let manifest = capture.manifest
        guard manifest.hasSupportedSchemaVersion else {
            throw
                LibreReverseMeetingCapturePublicationError
                .unsupportedManifestSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.state == .completed else {
            throw LibreReverseMeetingCapturePublicationError.captureNotCompleted(manifest.state)
        }
        guard manifest.writerStatus == "completed" else {
            throw LibreReverseMeetingCapturePublicationError.writerNotCompleted(
                manifest.writerStatus
            )
        }
        if let error = manifest.writerError ?? manifest.streamError {
            throw LibreReverseMeetingCapturePublicationError.captureReportedError(error)
        }
        try validateManifestMetadata(manifest)
        let staged = capture.stagingMediaURL.standardizedFileURL
        let declared = URL(fileURLWithPath: manifest.outputPath).standardizedFileURL
        guard staged == declared else {
            throw LibreReverseMeetingCapturePublicationError.outputPathMismatch(
                expected: staged.path,
                actual: declared.path
            )
        }
        let duration = manifest.finishedAt.timeIntervalSince(manifest.startedAt)
        guard duration > 0 else {
            throw LibreReverseMeetingCapturePublicationError.invalidDuration(duration)
        }

        let xid = capture.publicationXID ?? XID.generate(at: manifest.startedAt)
        if manifest.schemaVersion >= 5, manifest.publicationXID == nil {
            throw LibreReverseMeetingCapturePublicationError.missingManifestPublicationXID
        }
        if manifest.schemaVersion >= 5, !XID.isValid(xid) {
            throw LibreReverseMeetingCapturePublicationError.invalidPublicationXID(xid)
        }
        if let manifestXID = manifest.publicationXID, manifestXID != xid {
            throw LibreReverseMeetingCapturePublicationError.publicationXIDMismatch(
                expected: xid,
                actual: manifestXID
            )
        }
        let relativePath = VideoStorage.relativePath(
            xid: xid,
            date: manifest.startedAt
        )
        let destination = configuration.mediaRoot.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: destination.path) {
            if !fileManager.fileExists(atPath: staged.path) {
                if let existing = try LibreReverseLibraryStore.publishedMeeting(
                    xid: xid,
                    configuration: configuration
                ) {
                    try validateMediaIntegrity(
                        at: destination,
                        manifest: manifest,
                        required: manifest.schemaVersion >= 4
                    )
                    return existing
                }
                // A prior COMMIT/ROLLBACK outcome may have been unknowable.
                // Once the database proves no publication, reclaim only bytes
                // cryptographically bound to this manifest. A path/XID match
                // alone cannot distinguish the capture from an unrelated file.
                try validateMediaIntegrity(
                    at: destination,
                    manifest: manifest,
                    required: true
                )
                try fileManager.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: destination, to: staged)
            } else {
                throw LibreReverseMeetingCapturePublicationError.destinationAlreadyExists(
                    destination.path)
            }
        }
        guard fileManager.fileExists(atPath: staged.path) else {
            throw LibreReverseMeetingCapturePublicationError.missingStagedMedia(staged.path)
        }
        try validateMediaIntegrity(
            at: staged,
            manifest: manifest,
            required: manifest.schemaVersion >= 4
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staged, to: destination)
        var published = false
        var publicationOutcomeUnknown = false
        defer {
            if !published, !publicationOutcomeUnknown,
                fileManager.fileExists(atPath: destination.path),
                !fileManager.fileExists(atPath: staged.path)
            {
                try? fileManager.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.moveItem(at: destination, to: staged)
            }
        }

        let transcriptText = capture.transcript?.text ?? ""
        let transcriptWords =
            capture.transcript.map {
                clock.persistenceWords(from: $0, speechSource: "unknown")
            } ?? []
        let event = LibreReverseMeetingEventInput(
            type: "meeting",
            status: "completed",
            title: capture.candidate.title,
            participants: participantsJSON(capture.candidate.calendarParticipants ?? []),
            detailsJSON: eventDetailsJSON(capture.candidate),
            calendarID: capture.candidate.calendarID,
            calendarEventID: capture.candidate.calendarEventID,
            calendarSeriesID: capture.candidate.calendarSeriesID
        )
        do {
            let result = try LibreReverseLibraryStore.publishMeeting(
                .init(
                    startDate: manifest.startedAt,
                    endDate: manifest.finishedAt,
                    windowName: capture.candidate.title,
                    browserURL: capture.candidate.url?.absoluteString,
                    relativeMediaPath: relativePath,
                    xid: xid,
                    width: manifest.width,
                    height: manifest.height,
                    frameRate: Double(manifest.requestedFrameRate),
                    audioStartTime: manifest.startedAt,
                    duration: duration,
                    transcriptText: transcriptText,
                    transcriptWords: transcriptWords,
                    event: event
                ), configuration: configuration)
            published = true
            return result
        } catch let libraryError as LibreReverseLibraryStoreError {
            if case .transactionOutcomeUnknown = libraryError {
                publicationOutcomeUnknown = true
            }
            throw libraryError
        }
    }

    /// Terminal manifests survive process crashes and are decoded from disk on
    /// launch. Validate every framework- and database-bound scalar before any
    /// staged file is moved or canonical row is opened for mutation.
    private static func validateManifestMetadata(
        _ manifest: HighFidelityMeetingCaptureManifest
    ) throws {
        let started = manifest.startedAt.timeIntervalSinceReferenceDate
        let finished = manifest.finishedAt.timeIntervalSinceReferenceDate
        guard started.isFinite, finished.isFinite else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "date interval"
            )
        }
        let duration = finished - started
        guard duration.isFinite else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "date interval"
            )
        }
        guard manifest.hostClockStartSeconds.isFinite,
            manifest.hostClockStartSeconds >= 0
        else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "host clock"
            )
        }
        guard manifest.displayID != 0 else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "display ID"
            )
        }
        guard manifest.width > 0, manifest.width <= Int(Int32.max / 2) else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField("width")
        }
        guard manifest.height > 0, manifest.height <= Int(Int32.max / 2) else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField("height")
        }
        guard manifest.requestedFrameRate > 0,
            manifest.requestedFrameRate
                <= HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
        else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "requested frame rate"
            )
        }
        guard manifest.expectedSourceFrameRate > 0,
            manifest.expectedSourceFrameRate
                <= HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
        else {
            throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                "expected source frame rate"
            )
        }
        if let requestedDuration = manifest.requestedDurationSeconds {
            guard requestedDuration.isFinite,
                requestedDuration > 0,
                requestedDuration
                    <= HighFidelityMeetingCaptureSession
                    .maximumSupportedRequestedDurationSeconds
            else {
                throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                    "requested duration"
                )
            }
        }
        if manifest.schemaVersion >= 6 {
            guard let evidence = manifest.mediaEvidence else {
                throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                    "terminal media evidence"
                )
            }
            let requiresAudio = manifest.capturesSystemAudio || manifest.capturesMicrophone
            guard evidence.durationSeconds.isFinite,
                evidence.durationSeconds > 0,
                evidence.videoTrackCount > 0,
                evidence.audioTrackCount >= 0,
                evidence.width == manifest.width,
                evidence.height == manifest.height,
                evidence.videoHasReadableSample,
                !requiresAudio
                    || (evidence.audioTrackCount > 0 && evidence.audioHasReadableSample)
            else {
                throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                    "terminal media evidence"
                )
            }
            let wallDuration = manifest.finishedAt.timeIntervalSince(manifest.startedAt)
            let tolerance = max(1, 2 / Double(manifest.requestedFrameRate))
            guard abs(evidence.durationSeconds - wallDuration) <= tolerance else {
                throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                    "terminal media duration"
                )
            }
            if manifest.finalizationReason != "processCrashRecovered",
                let issue = manifest.timestamps.terminalValidationIssue(
                    capturesSystemAudio: manifest.capturesSystemAudio,
                    capturesMicrophone: manifest.capturesMicrophone
                )
            {
                throw LibreReverseMeetingCapturePublicationError.invalidManifestField(
                    "terminal capture telemetry (\(issue))"
                )
            }
        }
    }

    private static func validateMediaIntegrity(
        at url: URL,
        manifest: HighFidelityMeetingCaptureManifest,
        required: Bool
    ) throws {
        let mediaValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard mediaValues.isRegularFile == true,
            mediaValues.isSymbolicLink != true
        else {
            throw LibreReverseMeetingCapturePublicationError.unsupportedMediaFileType(
                url.path
            )
        }
        guard let expectedByteCount = manifest.outputByteCount,
            let expectedSHA256 = manifest.outputSHA256,
            !expectedSHA256.isEmpty
        else {
            if required {
                throw LibreReverseMeetingCapturePublicationError.missingOutputIntegrity(
                    url.path
                )
            }
            return
        }
        let actual = try ArchiveIntegrityEngine.hash(file: url)
        guard actual.byteCount == expectedByteCount,
            actual.sha256 == expectedSHA256.lowercased()
        else {
            throw LibreReverseMeetingCapturePublicationError.outputIntegrityMismatch(
                path: url.path,
                expectedByteCount: expectedByteCount,
                actualByteCount: actual.byteCount,
                expectedSHA256: expectedSHA256.lowercased(),
                actualSHA256: actual.sha256
            )
        }
    }

    private static func eventDetailsJSON(
        _ candidate: LibreReverseMeetingCandidate
    ) -> String? {
        var object: [String: Any] = [
            "provider": candidate.provider.legacyPersistenceValue,
            "source": candidate.source.rawValue,
        ]
        if let bundleIdentifier = candidate.bundleIdentifier {
            object["bundleIdentifier"] = bundleIdentifier
        }
        if let windowID = candidate.windowID { object["windowID"] = windowID }
        if let url = candidate.url?.absoluteString { object["url"] = url }
        if let calendarTitle = candidate.calendarTitle {
            object["calendarTitle"] = calendarTitle
        }
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func participantsJSON(_ participants: [String]) -> String? {
        guard !participants.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: participants,
                options: [.sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Product publication is not complete until the local transcription job is
/// durable. If queue persistence fails after the canonical SQLite commit, the
/// staging journal stays in place; replay resolves the same XID idempotently and
/// retries this queue write instead of silently losing the transcript forever.
public enum LibreReverseMeetingPublicationPipeline {
    public static func publishAndEnqueue(
        _ capture: LibreReverseFinalizedMeetingCapture,
        configuration: LibreReverseLibraryConfiguration,
        transcriptionQueue: LibreReverseMeetingTranscriptionQueue
    ) throws -> LibreReversePublishedMeeting {
        guard let publicationXID = capture.publicationXID, !publicationXID.isEmpty else {
            throw LibreReverseMeetingCapturePublicationError.missingPublicationXID
        }
        return try transcriptionQueue.withExclusiveAccess {
            let published = try LibreReverseMeetingCaptureFinalizer.publish(
                capture,
                configuration: configuration
            )
            if published.transcriptDocumentID == nil {
                try transcriptionQueue.enqueueAssumingExclusiveAccess(
                    .init(
                        publicationXID: publicationXID,
                        segmentID: published.segmentID,
                        videoID: published.videoID,
                        title: capture.candidate.title ?? "Meeting",
                        relativeMediaPath: VideoStorage.relativePath(
                            xid: publicationXID,
                            date: capture.manifest.startedAt
                        )
                    ))
            }
            return published
        }
    }
}
#endif
