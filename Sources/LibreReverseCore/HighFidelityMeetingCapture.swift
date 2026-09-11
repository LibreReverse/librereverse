#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum HighFidelityMeetingCaptureError: Error, CustomStringConvertible, LocalizedError {
    public var errorDescription: String? { description }
    case displayNotFound(CGDirectDisplayID)
    case invalidFrameRate(Int)
    case invalidRequestedDuration(Double)
    case writerAppendFailed(mediaType: String, underlying: Error?)
    case writerFinishFailed(Error?)
    case finalMediaValidationFailed(String)
    case recordingOutputFinishTimedOut(TimeInterval)
    case invalidLifecycle(expected: String, actual: String)

    public var description: String {
        switch self {
        case .displayNotFound(let displayID):
            return "ScreenCaptureKit could not find display \(displayID)"
        case .invalidFrameRate(let frameRate):
            return "Invalid meeting capture frame rate \(frameRate)"
        case .invalidRequestedDuration(let duration):
            return "Invalid meeting capture duration \(duration)"
        case .writerAppendFailed(let mediaType, let error):
            return
                "Meeting writer failed while appending \(mediaType): \(error?.localizedDescription ?? "unknown error")"
        case .writerFinishFailed(let error):
            return
                "Meeting writer failed to finish: \(error?.localizedDescription ?? "unknown error")"
        case .finalMediaValidationFailed(let message):
            return "Meeting writer produced invalid final media: \(message)"
        case .recordingOutputFinishTimedOut(let timeout):
            return "Meeting recording output did not finish within \(timeout) seconds"
        case .invalidLifecycle(let expected, let actual):
            return "Meeting capture expected state \(expected), found \(actual)"
        }
    }
}

public enum HighFidelityMeetingCaptureState: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case completed
    case failed
}

/// Media facts independently read back from the finalized MP4. Schema-v6
/// product manifests carry this attestation so canonical publication cannot
/// mistake a writer callback plus matching bytes for playable meeting media.
public struct HighFidelityMeetingCaptureMediaEvidence: Codable, Equatable, Sendable {
    public let durationSeconds: TimeInterval
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let width: Int
    public let height: Int
    public let videoHasReadableSample: Bool
    public let audioHasReadableSample: Bool

    public init(
        durationSeconds: TimeInterval,
        videoTrackCount: Int,
        audioTrackCount: Int,
        width: Int,
        height: Int,
        videoHasReadableSample: Bool,
        audioHasReadableSample: Bool
    ) {
        self.durationSeconds = durationSeconds
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.width = width
        self.height = height
        self.videoHasReadableSample = videoHasReadableSample
        self.audioHasReadableSample = audioHasReadableSample
    }
}

enum HighFidelityMeetingCaptureMediaInspector {
    static func inspect(
        url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        requiresAudio: Bool,
        capturedDuration: TimeInterval? = nil
    ) async throws -> HighFidelityMeetingCaptureMediaEvidence {
        let initialValues = try FileManager.default.attributesOfItem(atPath: url.path)
        let asset = AVURLAsset(url: url)
        let isReadable = try await asset.load(.isReadable)
        let isPlayable = try await asset.load(.isPlayable)
        let hasProtectedContent = try await asset.load(.hasProtectedContent)
        guard isReadable, isPlayable, !hasProtectedContent else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "asset is not readable and playable"
            )
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "duration is not positive and finite"
            )
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "video track is missing"
            )
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        let width = Int(abs(transformedSize.width).rounded())
        let height = Int(abs(transformedSize.height).rounded())
        guard width == expectedWidth, height == expectedHeight else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "video dimensions are \(width)x\(height), expected \(expectedWidth)x\(expectedHeight)"
            )
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if requiresAudio, audioTracks.isEmpty {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "requested audio track is missing"
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "video reader output is unsupported"
            )
        }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard reader.canAdd(output) else {
                throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                    "audio reader output is unsupported"
                )
            }
            reader.add(output)
            audioOutput = output
        }
        guard reader.startReading(), videoOutput.copyNextSampleBuffer() != nil else {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                reader.error?.localizedDescription ?? "video has no readable sample"
            )
        }
        let audioHasReadableSample = audioOutput?.copyNextSampleBuffer() != nil
        if requiresAudio, !audioHasReadableSample {
            throw HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                reader.error?.localizedDescription ?? "audio has no readable sample"
            )
        }
        reader.cancelReading()
        if let capturedDuration {
            guard MeetingCaptureFinalizationPolicy.coversCapture(
                mediaDuration: duration, capturedDuration: capturedDuration
            ) else {
                throw HighFidelityMeetingCaptureError.finalMediaValidationFailed("movie ends before capture telemetry")
            }
            // A readable first packet is insufficient after an abnormal stop.
            // Check the tail of every declared track, with bounded packet reads.
            for track in [videoTrack] + audioTracks {
                let tailReader = try AVAssetReader(asset: asset)
                tailReader.timeRange = CMTimeRange(
                    start: CMTime(seconds: max(0, duration - 2), preferredTimescale: 600),
                    end: CMTime(seconds: duration, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard tailReader.canAdd(output) else {
                    throw HighFidelityMeetingCaptureError.finalMediaValidationFailed("movie tail cannot be read")
                }
                tailReader.add(output)
                guard tailReader.startReading(), output.copyNextSampleBuffer() != nil else {
                    throw HighFidelityMeetingCaptureError.finalMediaValidationFailed("movie tail has no readable sample")
                }
                while output.copyNextSampleBuffer() != nil {}
                guard tailReader.status == .completed else {
                    throw HighFidelityMeetingCaptureError.finalMediaValidationFailed("movie tail is incomplete")
                }
            }
            let finalValues = try FileManager.default.attributesOfItem(atPath: url.path)
            guard initialValues[.size] as? NSNumber == finalValues[.size] as? NSNumber,
                initialValues[.modificationDate] as? Date == finalValues[.modificationDate] as? Date else {
                throw HighFidelityMeetingCaptureError.finalMediaValidationFailed("movie is still changing")
            }
        }
        return .init(
            durationSeconds: duration,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            width: width,
            height: height,
            videoHasReadableSample: true,
            audioHasReadableSample: audioHasReadableSample
        )
    }
}

public enum MeetingCaptureFinalizationPolicy {
    /// The native writer must release capture ownership before background
    /// screenshots can resume, even if optional audio work is still saving.
    public static func allowsSparseCapture(
        hasMeetingSession: Bool, hasMeetingOperation: Bool,
        nativeRecordingFinished: Bool, allowMeetingOperation: Bool = false
    ) -> Bool {
        (!hasMeetingSession || nativeRecordingFinished)
            && (!hasMeetingOperation || nativeRecordingFinished || allowMeetingOperation)
    }

    static func coversCapture(mediaDuration: TimeInterval, capturedDuration: TimeInterval) -> Bool {
        mediaDuration.isFinite && capturedDuration.isFinite && mediaDuration > 0
            && capturedDuration > 0 && mediaDuration + 1 >= capturedDuration
    }
}

/// One-shot native recording-output completion with a bounded async wait. The
/// callback may race registration or arrive after timeout; exactly one waiter is
/// resumed, and a late callback remains observable by a subsequent wait.
final class MeetingCaptureFinishLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait(timeoutSeconds: TimeInterval) async -> Bool {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { return false }
        return await withCheckedContinuation { continuation in
            let immediateResult: Bool? = lock.withLock {
                if finished { return true }
                guard waiter == nil else { return false }
                waiter = continuation
                return nil
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeoutSeconds
            ) { [weak self] in
                self?.expireWaiter()
            }
        }
    }

    func finish() {
        let continuation = lock.withLock {
            finished = true
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: true)
    }

    private func expireWaiter() {
        let continuation = lock.withLock {
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: false)
    }
}

public struct MeetingCaptureTrackStatistics: Codable, Equatable, Sendable {
    public var sampleBufferCount: Int = 0
    public var mediaSampleCount: Int = 0
    public var firstPresentationTimeSeconds: Double?
    public var lastPresentationTimeSeconds: Double?
    /// Optional preserves decoding of manifests written before variable-duration
    /// audio continuity used the preceding accepted buffer interval.
    public var lastExpectedIntervalSeconds: Double?
    public var largestPresentationGapSeconds: Double = 0
    public var discontinuityCount: Int = 0

    public init() {}

    public var coveredDurationSeconds: Double {
        guard let firstPresentationTimeSeconds, let lastPresentationTimeSeconds else {
            return 0
        }
        return max(0, lastPresentationTimeSeconds - firstPresentationTimeSeconds)
    }
}

/// Pure timestamp accounting used by both the live ScreenCaptureKit recorder and
/// deterministic tests. A gap is a discontinuity only after allowing 50% timing
/// jitter beyond the configured nominal interval.
public struct MeetingCaptureTimestampLedger: Codable, Equatable, Sendable {
    public let nominalVideoFrameIntervalSeconds: Double
    public private(set) var video = MeetingCaptureTrackStatistics()
    public private(set) var audio = MeetingCaptureTrackStatistics()
    public private(set) var microphone = MeetingCaptureTrackStatistics()
    public private(set) var incompleteVideoSampleCount = 0
    public private(set) var missingVideoFrameSlotCount = 0
    public private(set) var duplicateVideoFrameSlotCount = 0
    public private(set) var videoAppendBackpressureCount = 0
    public private(set) var audioAppendBackpressureCount = 0
    public private(set) var appendFailureCount = 0
    public private(set) var nonCompleteVideoStatusCounts: [String: Int] = [:]
    public private(set) var audioPeakAbsolute: Double = 0
    public private(set) var nonSilentAudioSampleBufferCount = 0
    public private(set) var microphonePeakAbsolute: Double = 0
    public private(set) var nonSilentMicrophoneSampleBufferCount = 0
    /// Optional preserves decoding of schema-2...5 manifests written before
    /// invalid callback timing was counted explicitly.
    public private(set) var invalidTimestampCount: Int? = 0
    /// Optional preserves the same compatibility for sample count/peak checks.
    public private(set) var invalidSampleMetadataCount: Int? = 0
    /// Optional preserves decoding of manifests written before invalid
    /// CMSampleBuffer deliveries were made terminal and auditable.
    public private(set) var invalidSampleBufferCount: Int? = 0

    public init(frameRate: Int) {
        nominalVideoFrameIntervalSeconds = 1 / Double(frameRate)
    }

    /// Product publication requires real samples from each requested source
    /// and no corrupt callbacks or failed writes. Timing gaps and backpressure
    /// remain quality diagnostics in the manifest: ordinary desktop scheduling
    /// jitter must not discard an otherwise playable meeting. The standalone
    /// fidelity validator can enforce stricter benchmark timing separately.
    public func terminalValidationIssue(
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) -> String? {
        guard video.sampleBufferCount > 0 else { return "video delivered no samples" }
        if capturesSystemAudio, audio.sampleBufferCount <= 0 {
            return "system audio delivered no samples"
        }
        if capturesMicrophone, microphone.sampleBufferCount <= 0 {
            return "microphone delivered no samples"
        }
        let counters: [(String, Int?)] = [
            ("invalid sample buffers", invalidSampleBufferCount),
            ("invalid sample timestamps", invalidTimestampCount),
            ("invalid sample metadata", invalidSampleMetadataCount),
            ("writer append failures", appendFailureCount),
        ]
        for (name, value) in counters {
            guard let value, value >= 0 else { return "\(name) is unavailable or invalid" }
            if value != 0 { return "\(name)=\(value)" }
        }
        return nil
    }

    @discardableResult
    public mutating func recordVideo(
        presentationTimeSeconds: Double,
        mediaSampleCount: Int = 1
    ) -> Bool {
        guard presentationTimeSeconds.isFinite,
            abs(presentationTimeSeconds) <= Self.maximumSafeTimestampSeconds,
            nominalVideoFrameIntervalSeconds.isFinite,
            nominalVideoFrameIntervalSeconds > 0
        else {
            recordInvalidTimestamp()
            return false
        }
        guard mediaSampleCount > 0,
            mediaSampleCount <= Int.max - video.mediaSampleCount
        else {
            recordInvalidSampleMetadata()
            return false
        }
        let first = video.firstPresentationTimeSeconds ?? presentationTimeSeconds
        guard
            let currentSlot = videoSlot(
                presentationTimeSeconds,
                relativeTo: first
            )
        else {
            recordInvalidTimestamp()
            return false
        }
        if video.sampleBufferCount > 0 {
            let previous = video.lastPresentationTimeSeconds ?? presentationTimeSeconds
            guard let previousSlot = videoSlot(previous, relativeTo: first) else {
                recordInvalidTimestamp()
                return false
            }
            if currentSlot <= previousSlot {
                Self.increment(&duplicateVideoFrameSlotCount)
            } else if currentSlot > previousSlot + 1 {
                Self.add(
                    currentSlot - previousSlot - 1,
                    to: &missingVideoFrameSlotCount
                )
            }
        }
        Self.record(
            presentationTimeSeconds: presentationTimeSeconds,
            mediaSampleCount: mediaSampleCount,
            expectedInterval: nominalVideoFrameIntervalSeconds,
            statistics: &video
        )
        return true
    }

    @discardableResult
    public mutating func recordAudio(
        presentationTimeSeconds: Double,
        durationSeconds: Double,
        mediaSampleCount: Int,
        peakAbsolute: Double? = nil
    ) -> Bool {
        guard presentationTimeSeconds.isFinite,
            abs(presentationTimeSeconds) <= Self.maximumSafeTimestampSeconds,
            durationSeconds.isFinite,
            durationSeconds > 0,
            durationSeconds <= Self.maximumSafeTimestampSeconds
        else {
            recordInvalidTimestamp()
            return false
        }
        guard mediaSampleCount > 0,
            mediaSampleCount <= Int.max - audio.mediaSampleCount,
            peakAbsolute.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            recordInvalidSampleMetadata()
            return false
        }
        Self.record(
            presentationTimeSeconds: presentationTimeSeconds,
            mediaSampleCount: mediaSampleCount,
            expectedInterval: max(durationSeconds, 0),
            statistics: &audio
        )
        if let peakAbsolute {
            audioPeakAbsolute = max(audioPeakAbsolute, peakAbsolute)
            if peakAbsolute > 0.000_1 {
                Self.increment(&nonSilentAudioSampleBufferCount)
            }
        }
        return true
    }

    @discardableResult
    public mutating func recordMicrophone(
        presentationTimeSeconds: Double,
        durationSeconds: Double,
        mediaSampleCount: Int,
        peakAbsolute: Double? = nil
    ) -> Bool {
        guard presentationTimeSeconds.isFinite,
            abs(presentationTimeSeconds) <= Self.maximumSafeTimestampSeconds,
            durationSeconds.isFinite,
            durationSeconds > 0,
            durationSeconds <= Self.maximumSafeTimestampSeconds
        else {
            recordInvalidTimestamp()
            return false
        }
        guard mediaSampleCount > 0,
            mediaSampleCount <= Int.max - microphone.mediaSampleCount,
            peakAbsolute.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            recordInvalidSampleMetadata()
            return false
        }
        Self.record(
            presentationTimeSeconds: presentationTimeSeconds,
            mediaSampleCount: mediaSampleCount,
            expectedInterval: max(durationSeconds, 0),
            statistics: &microphone
        )
        if let peakAbsolute {
            microphonePeakAbsolute = max(microphonePeakAbsolute, peakAbsolute)
            if peakAbsolute > 0.000_1 {
                Self.increment(&nonSilentMicrophoneSampleBufferCount)
            }
        }
        return true
    }

    public mutating func recordIncompleteVideoSample(statusRawValue: Int?) {
        Self.increment(&incompleteVideoSampleCount)
        let key = statusRawValue.map { "raw-\($0)" } ?? "missing-status"
        var count = nonCompleteVideoStatusCounts[key, default: 0]
        Self.increment(&count)
        nonCompleteVideoStatusCounts[key] = count
    }

    public mutating func recordBackpressure(mediaType: AVMediaType) {
        if mediaType == .video {
            Self.increment(&videoAppendBackpressureCount)
        } else if mediaType == .audio {
            Self.increment(&audioAppendBackpressureCount)
        }
    }

    public mutating func recordAppendFailure() {
        Self.increment(&appendFailureCount)
    }

    public mutating func recordInvalidSampleBuffer() {
        var count = invalidSampleBufferCount ?? 0
        Self.increment(&count)
        invalidSampleBufferCount = count
    }

    private func videoSlot(
        _ presentationTimeSeconds: Double,
        relativeTo firstPresentationTimeSeconds: Double
    ) -> Int? {
        let raw =
            (presentationTimeSeconds - firstPresentationTimeSeconds)
            / nominalVideoFrameIntervalSeconds
        guard raw.isFinite, abs(raw) <= Double(Int.max / 2) else { return nil }
        return Int(raw.rounded())
    }

    private mutating func recordInvalidTimestamp() {
        var count = invalidTimestampCount ?? 0
        Self.increment(&count)
        invalidTimestampCount = count
    }

    private mutating func recordInvalidSampleMetadata() {
        var count = invalidSampleMetadataCount ?? 0
        Self.increment(&count)
        invalidSampleMetadataCount = count
    }

    private static let maximumSafeTimestampSeconds = Double(Int.max / 2_000)

    private static func increment(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }

    private static func add(_ amount: Int, to value: inout Int) {
        guard amount > 0 else { return }
        value = amount > Int.max - value ? Int.max : value + amount
    }

    private static func record(
        presentationTimeSeconds: Double,
        mediaSampleCount: Int,
        expectedInterval: Double,
        statistics: inout MeetingCaptureTrackStatistics
    ) {
        if let previous = statistics.lastPresentationTimeSeconds {
            let gap = presentationTimeSeconds - previous
            let precedingInterval =
                statistics.lastExpectedIntervalSeconds ?? expectedInterval
            statistics.largestPresentationGapSeconds = max(
                statistics.largestPresentationGapSeconds,
                gap
            )
            if gap < 0
                || (precedingInterval > 0 && gap > precedingInterval * 1.5)
            {
                Self.increment(&statistics.discontinuityCount)
            }
        } else {
            statistics.firstPresentationTimeSeconds = presentationTimeSeconds
        }
        statistics.lastPresentationTimeSeconds = presentationTimeSeconds
        statistics.lastExpectedIntervalSeconds = expectedInterval
        Self.increment(&statistics.sampleBufferCount)
        Self.add(mediaSampleCount, to: &statistics.mediaSampleCount)
    }
}

public struct HighFidelityMeetingCaptureConfiguration: Sendable {
    public let outputURL: URL
    public let manifestURL: URL
    public let displayID: CGDirectDisplayID
    public let frameRate: Int
    public let expectedSourceFrameRate: Int
    public let capturesSystemAudio: Bool
    public let capturesMicrophone: Bool
    public let microphoneDeviceID: String?
    public let showsCursor: Bool
    public let requestedDurationSeconds: Double?
    public let publicationXID: String?

    public init(
        outputURL: URL,
        manifestURL: URL,
        displayID: CGDirectDisplayID,
        frameRate: Int = 30,
        expectedSourceFrameRate: Int? = nil,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        showsCursor: Bool = true,
        requestedDurationSeconds: Double? = nil,
        publicationXID: String? = nil
    ) {
        self.outputURL = outputURL
        self.manifestURL = manifestURL
        self.displayID = displayID
        self.frameRate = frameRate
        self.expectedSourceFrameRate = expectedSourceFrameRate ?? frameRate
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.showsCursor = showsCursor
        self.requestedDurationSeconds = requestedDurationSeconds
        self.publicationXID = publicationXID
    }
}

public struct HighFidelityMeetingCaptureManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersions = 2...6

    public let schemaVersion: Int
    public let state: HighFidelityMeetingCaptureState
    public let finalizationReason: String
    public let outputPath: String
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let requestedFrameRate: Int
    public let expectedSourceFrameRate: Int
    public let capturesSystemAudio: Bool
    public let capturesMicrophone: Bool
    public let microphoneDeviceID: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let hostClockStartSeconds: Double
    public let writerStatus: String
    public let writerError: String?
    public let streamError: String?
    public let timestamps: MeetingCaptureTimestampLedger
    public let requestedDurationSeconds: Double?
    public let outputByteCount: Int64?
    public let outputSHA256: String?
    public let publicationXID: String?
    public let mediaEvidence: HighFidelityMeetingCaptureMediaEvidence?

    public init(
        schemaVersion: Int = 2,
        state: HighFidelityMeetingCaptureState,
        finalizationReason: String,
        outputPath: String,
        displayID: UInt32,
        width: Int,
        height: Int,
        requestedFrameRate: Int,
        expectedSourceFrameRate: Int,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        microphoneDeviceID: String?,
        startedAt: Date,
        finishedAt: Date,
        hostClockStartSeconds: Double,
        writerStatus: String,
        writerError: String?,
        streamError: String?,
        timestamps: MeetingCaptureTimestampLedger,
        requestedDurationSeconds: Double? = nil,
        outputByteCount: Int64? = nil,
        outputSHA256: String? = nil,
        publicationXID: String? = nil,
        mediaEvidence: HighFidelityMeetingCaptureMediaEvidence? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.finalizationReason = finalizationReason
        self.outputPath = outputPath
        self.displayID = displayID
        self.width = width
        self.height = height
        self.requestedFrameRate = requestedFrameRate
        self.expectedSourceFrameRate = expectedSourceFrameRate
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.hostClockStartSeconds = hostClockStartSeconds
        self.writerStatus = writerStatus
        self.writerError = writerError
        self.streamError = streamError
        self.timestamps = timestamps
        self.requestedDurationSeconds = requestedDurationSeconds
        self.outputByteCount = outputByteCount
        self.outputSHA256 = outputSHA256?.lowercased()
        self.publicationXID = publicationXID
        self.mediaEvidence = mediaEvidence
    }

    public var hasSupportedSchemaVersion: Bool {
        Self.supportedSchemaVersions.contains(schemaVersion)
    }

    public static func requiresOutputIntegrity(
        state: HighFidelityMeetingCaptureState,
        writerStatus: String
    ) -> Bool {
        state == .completed || writerStatus == "completed"
    }
}

/// Dense screen plus system-audio capture for the explicit meeting validation
/// mode. This is deliberately separate from `ScreenRecordingSession`, whose
/// sparse, diff-gated screenshots implement ordinary visual memory.
public final class HighFidelityMeetingCaptureSession: NSObject, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable
{
    /// Both values eventually cross fixed-width framework boundaries. Keeping
    /// the checks here means malformed developer/test configuration fails
    /// before ScreenCaptureKit, permissions, or output files are
    /// touched.
    public static let maximumSupportedFrameRate = Int(Int32.max / 2)
    public static let maximumSupportedRequestedDurationSeconds =
        Double(UInt64.max / 1_000_000_000)

    public private(set) var state: HighFidelityMeetingCaptureState = .idle

    private let configuration: HighFidelityMeetingCaptureConfiguration
    private let sampleQueue = DispatchQueue(label: "local.librereverse.meeting-capture.samples")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var ledger: MeetingCaptureTimestampLedger
    private var startDate: Date?
    private var hostClockStart = CMTime.invalid
    private var captureWidth = 0
    private var captureHeight = 0
    private var appendError: Error?
    private var streamError: Error?
    private let systemRecordingFinishLatch = MeetingCaptureFinishLatch()
    private var systemRecordingError: Error?
    private var systemRecordingOutput: SCRecordingOutput?
    private var terminalMediaEvidence: HighFidelityMeetingCaptureMediaEvidence?
    private var speechCapture: MeetingSpeechCapture?

    public init(configuration: HighFidelityMeetingCaptureConfiguration) throws {
        guard configuration.frameRate > 0,
            configuration.frameRate <= Self.maximumSupportedFrameRate
        else {
            throw HighFidelityMeetingCaptureError.invalidFrameRate(configuration.frameRate)
        }
        self.configuration = configuration
        guard configuration.expectedSourceFrameRate > 0,
            configuration.expectedSourceFrameRate <= Self.maximumSupportedFrameRate
        else {
            throw HighFidelityMeetingCaptureError.invalidFrameRate(
                configuration.expectedSourceFrameRate
            )
        }
        if let duration = configuration.requestedDurationSeconds {
            guard duration.isFinite,
                duration > 0,
                duration <= Self.maximumSupportedRequestedDurationSeconds
            else {
                throw HighFidelityMeetingCaptureError.invalidRequestedDuration(duration)
            }
        }
        ledger = MeetingCaptureTimestampLedger(
            frameRate: configuration.expectedSourceFrameRate
        )
        super.init()
    }

    public func timestampSnapshot() -> MeetingCaptureTimestampLedger {
        stateLock.withLock { ledger }
    }

    /// Snapshot the immutable facts needed to recover an MP4 that
    /// SCRecordingOutput finalized after an abrupt process exit. This is only
    /// exposed after `startCapture()` succeeds; a pre-start journal is not
    /// sufficient evidence for crash publication.
    @MainActor
    public func recoveryCheckpoint()
        -> LibreReverseMeetingCaptureRecoveryCheckpoint?
    {
        guard state == .recording, let startDate, hostClockStart.isValid,
            captureWidth > 0, captureHeight > 0
        else { return nil }
        return .init(
            startedAt: startDate,
            hostClockStartSeconds: hostClockStart.seconds,
            displayID: configuration.displayID,
            width: captureWidth,
            height: captureHeight,
            requestedFrameRate: configuration.frameRate,
            expectedSourceFrameRate: configuration.expectedSourceFrameRate,
            capturesSystemAudio: configuration.capturesSystemAudio,
            capturesMicrophone: configuration.capturesMicrophone,
            microphoneDeviceID: configuration.microphoneDeviceID
        )
    }

    public func terminalErrorDescription() -> String? {
        stateLock.withLock {
            appendError?.localizedDescription
                ?? streamError?.localizedDescription
                ?? systemRecordingError?.localizedDescription
        }
    }

    @MainActor
    public func start() async throws {
        guard state == .idle else {
            throw HighFidelityMeetingCaptureError.invalidLifecycle(
                expected: HighFidelityMeetingCaptureState.idle.rawValue,
                actual: state.rawValue
            )
        }
        state = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard
                let display = content.displays.first(where: {
                    $0.displayID == configuration.displayID
                })
            else {
                throw HighFidelityMeetingCaptureError.displayNotFound(configuration.displayID)
            }
            // `SCDisplay.width/height` follow the logical display mode on a
            // Retina Mac. Use native pixels to preserve detail in recorded frames.
            let displayMode = CGDisplayCopyDisplayMode(configuration.displayID)
            let nativeWidth =
                displayMode?.pixelWidth
                ?? CGDisplayPixelsWide(configuration.displayID)
            let nativeHeight =
                displayMode?.pixelHeight
                ?? CGDisplayPixelsHigh(configuration.displayID)
            captureWidth = nativeWidth
            captureHeight = nativeHeight
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = nativeWidth
            streamConfiguration.height = nativeHeight
            streamConfiguration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(configuration.frameRate)
            )
            streamConfiguration.queueDepth = 8
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfiguration.showsCursor = configuration.showsCursor
            streamConfiguration.capturesAudio = configuration.capturesSystemAudio
            // The validation process emits no audio. Capture every system
            // source so a fixture player cannot be silently filtered through
            // an unexpected process/audit-token relationship. Production may
            // set an evidence-backed self-exclusion policy later.
            streamConfiguration.excludesCurrentProcessAudio = false
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2
            if configuration.capturesMicrophone {
                streamConfiguration.captureMicrophone = true
                streamConfiguration.microphoneCaptureDeviceID =
                    configuration.microphoneDeviceID
            }

            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: self
            )
            try prepareSystemRecordingOutput(stream: stream)
            if configuration.capturesMicrophone, MeetingSpeechProcessor.bundledLibraryURL != nil {
                do {
                    speechCapture = try MeetingSpeechCapture(movie: configuration.outputURL, systemAudio: configuration.capturesSystemAudio)
                } catch {
                    FileHandle.standardError.write(Data("Separate microphone capture unavailable; keeping native audio: \(error.localizedDescription)\n".utf8))
                }
            }
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if configuration.capturesMicrophone {
                try stream.addStreamOutput(
                    self,
                    type: .microphone,
                    sampleHandlerQueue: sampleQueue
                )
            }
            self.stream = stream
            startDate = Date()
            hostClockStart = CMClockGetTime(CMClockGetHostTimeClock())
            try await stream.startCapture()
            state = .recording
        } catch {
            state = .failed
            throw error
        }
    }

    @MainActor
    public func interruptForValidation(reason: String) async {
        guard state == .recording else { return }
        let activeStream = stream
        stream = nil
        if let activeStream {
            do {
                try await activeStream.stopCapture()
            } catch {
                stateLock.withLock { streamError = error }
            }
        }
        stateLock.withLock {
            if streamError == nil {
                streamError = NSError(
                    domain: "local.librereverse.meeting-validation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
            }
        }
        state = .failed
    }

    @MainActor
    public func stop(
        finalizationReason: String,
        nativeRecordingDidFinish: (@MainActor () async -> Void)? = nil
    ) async throws -> HighFidelityMeetingCaptureManifest
    {
        guard state == .recording || state == .failed else {
            throw HighFidelityMeetingCaptureError.invalidLifecycle(
                expected: "recording-or-failed",
                actual: state.rawValue
            )
        }
        state = .stopping
        if let stream {
            // Stop once. Removing SCRecordingOutput and immediately stopping
            // the stream can race two writer finalizations in the system service.
            // The async overlay can also wait forever after an XPC interruption,
            // so explicitly bound its callback just like the movie callback.
            let stopLatch = MeetingCaptureFinishLatch()
            stream.stopCapture { [weak self] error in
                if let error { self?.stateLock.withLock { self?.streamError = error } }
                stopLatch.finish()
            }
            if !(await stopLatch.wait(timeoutSeconds: Self.systemRecordingFinishTimeoutSeconds)) {
                stateLock.withLock {
                    if streamError == nil {
                        streamError = NSError(domain: "local.librereverse.meeting-capture", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Screen recording service did not confirm shutdown within 30 seconds"])
                    }
                }
            }
        }
        sampleQueue.sync { speechCapture?.endSamples() }
        await speechCapture?.finish()
        if systemRecordingOutput != nil {
            let didFinish = await systemRecordingFinishLatch.wait(
                timeoutSeconds: Self.systemRecordingFinishTimeoutSeconds
            )
            if !didFinish,
                stateLock.withLock({ streamError == nil && systemRecordingError == nil && appendError == nil }) {
                // Some service shutdowns finish the MP4 without delivering the
                // delegate callback. Never accept a partial movie on that basis:
                // require playable media extending to the last captured frame.
                let expectedDuration = stateLock.withLock { ledger.video.coveredDurationSeconds }
                if let evidence = try? await HighFidelityMeetingCaptureMediaInspector.inspect(
                    url: configuration.outputURL,
                    expectedWidth: captureWidth,
                    expectedHeight: captureHeight,
                    requiresAudio: configuration.capturesSystemAudio || configuration.capturesMicrophone,
                    capturedDuration: expectedDuration
                ) {
                    terminalMediaEvidence = evidence
                    FileHandle.standardError.write(Data("Meeting completion callback missing; finalized media passed readback validation.\n".utf8))
                }
            }
            if !didFinish && terminalMediaEvidence == nil {
                stateLock.withLock {
                    if systemRecordingError == nil {
                        systemRecordingError =
                            HighFidelityMeetingCaptureError.recordingOutputFinishTimedOut(
                                Self.systemRecordingFinishTimeoutSeconds
                            )
                    }
                }
            }
        }

        let capturedAppendError = stateLock.withLock { appendError }
        let capturedStreamError = stateLock.withLock { streamError }
        let capturedSystemRecordingError = stateLock.withLock { systemRecordingError }
        if let capturedAppendError {
            state = .failed
            _ = try writeManifest(
                finalizationReason: finalizationReason,
                streamError: capturedStreamError,
                writerError: capturedAppendError
            )
            throw HighFidelityMeetingCaptureError.writerAppendFailed(
                mediaType: "sample",
                underlying: capturedAppendError
            )
        }
        if let capturedSystemRecordingError {
            state = .failed
            _ = try writeManifest(
                finalizationReason: finalizationReason,
                streamError: capturedStreamError,
                writerError: capturedSystemRecordingError
            )
            throw HighFidelityMeetingCaptureError.writerFinishFailed(
                capturedSystemRecordingError
            )
        }
        if capturedStreamError == nil,
            let issue = stateLock.withLock({
                ledger.terminalValidationIssue(
                    capturesSystemAudio: configuration.capturesSystemAudio,
                    capturesMicrophone: configuration.capturesMicrophone
                )
            })
        {
            state = .failed
            let validationError = HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "capture telemetry is incomplete: \(issue)"
            )
            _ = try writeManifest(
                finalizationReason: finalizationReason,
                streamError: capturedStreamError,
                writerError: validationError
            )
            throw validationError
        }
        if capturedStreamError == nil && terminalMediaEvidence == nil {
            do {
                terminalMediaEvidence = try await HighFidelityMeetingCaptureMediaInspector.inspect(
                    url: configuration.outputURL,
                    expectedWidth: captureWidth,
                    expectedHeight: captureHeight,
                    requiresAudio: configuration.capturesSystemAudio
                        || configuration.capturesMicrophone
                )
            } catch {
                state = .failed
                let validationError =
                    error as? HighFidelityMeetingCaptureError
                    ?? .finalMediaValidationFailed(error.localizedDescription)
                _ = try writeManifest(
                    finalizationReason: finalizationReason,
                    streamError: capturedStreamError,
                    writerError: validationError
                )
                throw validationError
            }
        }
        if capturedStreamError == nil {
            await nativeRecordingDidFinish?()
            _ = await MeetingSpeechCapture.enhanceIfReady(movie: configuration.outputURL)
            let compression = try await MeetingVideoCompression.optimizeFinalizedStagingMovie(
                at: configuration.outputURL
            )
            if case .replaced = compression {
                terminalMediaEvidence = try await HighFidelityMeetingCaptureMediaInspector.inspect(
                    url: configuration.outputURL,
                    expectedWidth: captureWidth, expectedHeight: captureHeight,
                    requiresAudio: configuration.capturesSystemAudio || configuration.capturesMicrophone,
                    capturedDuration: stateLock.withLock { ledger.video.coveredDurationSeconds }
                )
            }
            // Derive once while the finalized movie is still private staging media.
            // Publication hashes must include the embedded waveform; a derived
            // preview failure must not discard an otherwise valid recording.
            _ = try? await MeetingWaveformMetadata.prepareAndEmbed(
                forLocalMediaURL: configuration.outputURL
            )
        }
        state = capturedStreamError == nil ? .completed : .failed
        return try writeManifest(
            finalizationReason: finalizationReason,
            streamError: capturedStreamError,
            writerError: nil
        )
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else {
            let mediaType: String
            switch outputType {
            case .screen:
                mediaType = "video"
            case .audio:
                mediaType = "audio"
            default:
                if outputType == .microphone {
                    mediaType = "microphone"
                } else {
                    mediaType = "unknown"
                }
            }
            stateLock.withLock {
                ledger.recordInvalidSampleBuffer()
                recordInvalidSampleFailure(mediaType: mediaType)
            }
            return
        }
        let presentationTime = sampleBuffer.presentationTimeStamp.seconds
        switch outputType {
        case .screen:
            let statusRawValue = frameStatusRawValue(sampleBuffer)
            guard
                statusRawValue == SCFrameStatus.complete.rawValue
                    || statusRawValue == SCFrameStatus.started.rawValue
            else {
                stateLock.withLock {
                    ledger.recordIncompleteVideoSample(statusRawValue: statusRawValue)
                }
                return
            }
            let timingAccepted = stateLock.withLock {
                let accepted = ledger.recordVideo(
                    presentationTimeSeconds: presentationTime,
                    mediaSampleCount: sampleBuffer.numSamples
                )
                if !accepted { recordInvalidSampleFailure(mediaType: "video") }
                return accepted
            }
            guard timingAccepted else { return }
            speechCapture?.startVideo(at: sampleBuffer.presentationTimeStamp)
        case .audio:
            let peakAbsolute = audioPeakAbsoluteValue(sampleBuffer)
            let timingAccepted = stateLock.withLock {
                let accepted = ledger.recordAudio(
                    presentationTimeSeconds: presentationTime,
                    durationSeconds: sampleBuffer.duration.seconds,
                    mediaSampleCount: sampleBuffer.numSamples,
                    peakAbsolute: peakAbsolute
                )
                if !accepted { recordInvalidSampleFailure(mediaType: "audio") }
                return accepted
            }
            guard timingAccepted else { return }
            speechCapture?.append(sampleBuffer, microphone: false, peakAbsolute: peakAbsolute)
        default:
            if outputType == .microphone {
                stateLock.withLock {
                    let accepted = ledger.recordMicrophone(
                        presentationTimeSeconds: presentationTime,
                        durationSeconds: sampleBuffer.duration.seconds,
                        mediaSampleCount: sampleBuffer.numSamples,
                        peakAbsolute: audioPeakAbsoluteValue(sampleBuffer)
                    )
                    if !accepted { recordInvalidSampleFailure(mediaType: "microphone") }
                }
                speechCapture?.append(sampleBuffer, microphone: true)
            }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.withLock { streamError = error }
    }

    /// Must be called while `stateLock` is held.
    private func recordInvalidSampleFailure(mediaType: String) {
        guard appendError == nil else { return }
        appendError = NSError(
            domain: "local.librereverse.meeting-capture",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ScreenCaptureKit delivered invalid \(mediaType) sample metadata"
            ]
        )
    }

    private func prepareSystemRecordingOutput(stream: SCStream) throws {
        try FileManager.default.createDirectory(
            at: configuration.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = configuration.outputURL
        outputConfiguration.outputFileType = .mp4
        outputConfiguration.videoCodecType =
            outputConfiguration.availableVideoCodecTypes
                .contains(.hevc) ? .hevc : .h264
        let output = SCRecordingOutput(
            configuration: outputConfiguration,
            delegate: self
        )
        try stream.addRecordingOutput(output)
        systemRecordingOutput = output
    }

    private func frameStatusRawValue(_ sampleBuffer: CMSampleBuffer) -> Int? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else {
            return nil
        }
        return rawStatus
    }

    private func audioPeakAbsoluteValue(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = sampleBuffer.formatDescription,
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee,
            description.mFormatID == kAudioFormatLinearPCM,
            let blockBuffer = sampleBuffer.dataBuffer
        else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: rawBuffer.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        if description.mBitsPerChannel == 32,
            description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        {
            return bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.bindMemory(to: Float32.self).reduce(0) {
                    max($0, Double(abs($1)))
                }
            }
        }
        if description.mBitsPerChannel == 16,
            description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        {
            return bytes.withUnsafeBytes { rawBuffer in
                rawBuffer.bindMemory(to: Int16.self).reduce(0) {
                    max($0, Double(abs(Int($1))) / Double(Int16.max))
                }
            }
        }
        return nil
    }

    private func writeManifest(
        finalizationReason: String,
        streamError: Error?,
        writerError: Error?
    ) throws -> HighFidelityMeetingCaptureManifest {
        let writerStatus =
            systemRecordingOutput != nil
            ? (stateLock.withLock { systemRecordingError } == nil
                ? "completed" : "failed")
            : "uninitialized"
        let outputIntegrity =
            HighFidelityMeetingCaptureManifest.requiresOutputIntegrity(
                state: state,
                writerStatus: writerStatus
            )
            ? try ArchiveIntegrityEngine.hash(file: configuration.outputURL)
            : nil
        let finishedAt =
            if state == .completed, let startDate, let terminalMediaEvidence {
                startDate.addingTimeInterval(terminalMediaEvidence.durationSeconds)
            } else {
                Date()
            }
        let manifest = HighFidelityMeetingCaptureManifest(
            schemaVersion: configuration.publicationXID == nil ? 4 : 6,
            state: state,
            finalizationReason: finalizationReason,
            outputPath: configuration.outputURL.path,
            displayID: configuration.displayID,
            width: captureWidth,
            height: captureHeight,
            requestedFrameRate: configuration.frameRate,
            expectedSourceFrameRate: configuration.expectedSourceFrameRate,
            capturesSystemAudio: configuration.capturesSystemAudio,
            capturesMicrophone: configuration.capturesMicrophone,
            microphoneDeviceID: configuration.microphoneDeviceID,
            startedAt: startDate ?? Date(),
            finishedAt: finishedAt,
            hostClockStartSeconds: hostClockStart.seconds,
            writerStatus: writerStatus,
            writerError: writerError?.localizedDescription,
            streamError: streamError?.localizedDescription,
            timestamps: stateLock.withLock { ledger },
            requestedDurationSeconds: configuration.requestedDurationSeconds,
            outputByteCount: outputIntegrity?.byteCount,
            outputSHA256: outputIntegrity?.sha256,
            publicationXID: configuration.publicationXID,
            mediaEvidence: terminalMediaEvidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: configuration.manifestURL, options: .atomic)
        return manifest
    }

    private static let systemRecordingFinishTimeoutSeconds: TimeInterval = 30
}

extension HighFidelityMeetingCaptureSession: SCRecordingOutputDelegate {
    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    public func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        finishSystemRecording(with: error)
    }

    public func recordingOutputDidFinishRecording(
        _ recordingOutput: SCRecordingOutput
    ) {
        finishSystemRecording(with: nil)
    }

    private func finishSystemRecording(with error: Error?) {
        stateLock.withLock {
            if let error { systemRecordingError = error }
        }
        systemRecordingFinishLatch.finish()
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
