#if os(macOS)
import AVFoundation
import CoreVideo
import Darwin
import Foundation

/// Offline optimization of a finalized staging movie, before publication.
/// Native capture stays readable until a smaller replacement passes readback.
public enum MeetingVideoCompression {
    public static let frameRate = 30

    public static func targetBitRate(width: Int, height: Int) -> Int {
        // Retain native text pixels. At 3024×1964 this allows about 4 Mbps;
        // resolution scaling avoids applying a 1080p budget to a Retina display.
        Int(min(8_000_000, max(1_500_000, Double(width) * Double(height) * 0.68)))
    }

    public enum Outcome: Sendable, Equatable {
        case replaced(originalBytes: Int64, compressedBytes: Int64)
        case keptOriginal
    }

    /// Failure is best-effort: the finalized original remains the publication
    /// source. Cancellation is reported only after admitted native work drains.
    public static func optimizeFinalizedStagingMovie(at url: URL) async throws -> Outcome {
        try await optimizeFinalizedStagingMovie(at: url, nativeWorkStarted: nil)
    }

    /// Internal synchronization seam for deterministic native lifetime tests.
    static func optimizeFinalizedStagingMovie(at url: URL,
        nativeWorkStarted: (@Sendable () -> Void)?) async throws -> Outcome {
        try Task.checkCancellation()
        do { return try await optimize(url, nativeWorkStarted: nativeWorkStarted) }
        catch {
            try Task.checkCancellation()
            return .keptOriginal
        }
    }

    private static func optimize(_ url: URL, nativeWorkStarted: (@Sendable () -> Void)?) async throws -> Outcome {
        let original = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = original[.size] as? NSNumber, size.int64Value > 0 else { return .keptOriginal }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard videoTracks.count == 1, let video = videoTracks.first else { return .keptOriginal }
        let duration = try await asset.load(.duration)
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let width = Int(naturalSize.width.rounded()), height = Int(naturalSize.height.rounded())
        guard width > 0, height > 0, duration.seconds.isFinite, duration.seconds > 0 else { return .keptOriginal }
        let bitrate = targetBitRate(width: width, height: height)
        let nominalFrameRate = try await video.load(.nominalFrameRate)
        let estimatedVideoRate = try await video.load(.estimatedDataRate)
        // Avoid another lossy generation when the original already meets budget.
        guard Double(estimatedVideoRate) > Double(bitrate) * 1.2 else { return .keptOriginal }
        let parent = url.deletingLastPathComponent()
        let free = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let expected = Int64(min(Double(Int64.max / 4), duration.seconds * Double(bitrate) / 8 * 1.5))
        // AAC is copied, and native output can exceed its average-rate target.
        guard let free, free > expected + 256 * 1_024 * 1_024 else { return .keptOriginal }
        let workspace = parent.appendingPathComponent(".meeting-compression-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let candidate = workspace.appendingPathComponent("optimized.mp4")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: candidate, fileType: .mp4)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: max(1, nominalFrameRate),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return .keptOriginal }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { return .keptOriginal }
        reader.add(videoOutput); writer.add(videoInput)
        var channels = [MeetingCompressionChannel(output: videoOutput, input: videoInput, video: true)]
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard let format = descriptions.first else { return .keptOriginal }
            // Passthrough compressed packets preserves the original audio codec,
            // sample rate, channels and quality, including multiple audio tracks.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { return .keptOriginal }
            reader.add(output); writer.add(input)
            channels.append(.init(output: output, input: input, video: false))
        }
        try Task.checkCancellation()
        let work = MeetingCompressionWork(reader: reader, writer: writer, channels: channels, duration: duration, nativeWorkStarted: nativeWorkStarted)
        try await work.run()
        try Task.checkCancellation()
        let transformed = naturalSize.applying(transform)
        let evidence = try await HighFidelityMeetingCaptureMediaInspector.inspect(
            url: candidate, expectedWidth: Int(abs(transformed.width).rounded()),
            expectedHeight: Int(abs(transformed.height).rounded()), requiresAudio: !audioTracks.isEmpty,
            capturedDuration: duration.seconds)
        guard evidence.audioTrackCount == audioTracks.count,
              abs(evidence.durationSeconds - duration.seconds) <= 0.15 else { return .keptOriginal }
        // Packet presence alone does not prove the new encoder's output can
        // actually draw. Decode samples across the movie before replacement.
        let validationAsset = AVURLAsset(url: candidate)
        let generator = AVAssetImageGenerator(asset: validationAsset)
        generator.appliesPreferredTrackTransform = true
        for seconds in [0.0, duration.seconds / 2, max(0, duration.seconds - 0.1)] {
            _ = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            try Task.checkCancellation()
        }
        let optimized = try FileManager.default.attributesOfItem(atPath: candidate.path)
        guard let newSize = optimized[.size] as? NSNumber,
              newSize.int64Value < size.int64Value * 9 / 10 else { return .keptOriginal }
        let current = try FileManager.default.attributesOfItem(atPath: url.path)
        guard current[.size] as? NSNumber == size,
              current[.modificationDate] as? Date == original[.modificationDate] as? Date,
              current[.systemFileNumber] as? NSNumber == original[.systemFileNumber] as? NSNumber else { return .keptOriginal }
        let handle = try FileHandle(forWritingTo: candidate)
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        // Same-volume POSIX rename replaces the path atomically. No await after
        // this boundary: a failed candidate never removes the usable original.
        guard rename(candidate.path, url.path) == 0 else { return .keptOriginal }
        return .replaced(originalBytes: size.int64Value, compressedBytes: newSize.int64Value)
    }
}

private struct MeetingCompressionChannel {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    let video: Bool
}

/// Each callback and its state live on one serial queue. Cancellation does not
/// tear down AVFoundation mid-write; callers retain ownership until completion.
private final class MeetingCompressionWork: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let channels: [MeetingCompressionChannel]
    let duration: CMTime
    let nativeWorkStarted: (@Sendable () -> Void)?
    let queue = DispatchQueue(label: "LibreReverse.meeting-compression", qos: .utility)
    var remaining: Int
    var ended = Set<Int>()
    var continuation: CheckedContinuation<Void, Error>?
    var watchdog: DispatchSourceTimer?
    var lastProgress = DispatchTime.now().uptimeNanoseconds
    static let noProgressNanoseconds: UInt64 = 60 * 1_000_000_000

    init(reader: AVAssetReader, writer: AVAssetWriter, channels: [MeetingCompressionChannel], duration: CMTime, nativeWorkStarted: (@Sendable () -> Void)?) {
        self.reader = reader; self.writer = writer; self.channels = channels
        self.duration = duration; remaining = channels.count
        self.nativeWorkStarted = nativeWorkStarted
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                self.continuation = continuation
                guard writer.startWriting(), reader.startReading() else {
                    complete(writer.error ?? reader.error ?? failure()); return
                }
                writer.startSession(atSourceTime: .zero)
                nativeWorkStarted?()
                lastProgress = DispatchTime.now().uptimeNanoseconds
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.checkProgress() }
                watchdog = timer
                timer.resume()
                for (index, channel) in channels.enumerated() {
                    channel.input.requestMediaDataWhenReady(on: queue) { [weak self] in
                        guard let self else { return }
                        guard self.continuation != nil, !ended.contains(index) else { return }
                        while channel.input.isReadyForMoreMediaData {
                            guard let sample = channel.output.copyNextSampleBuffer() else {
                                finish(index); return
                            }
                            guard channel.input.append(sample) else {
                                complete(writer.error ?? failure()); return
                            }
                            lastProgress = DispatchTime.now().uptimeNanoseconds
                        }
                        // A failed writer may never request another callback.
                        checkProgress()
                    }
                }
            }
        }
    }

    private func checkProgress() {
        guard continuation != nil else { return }
        if writer.status == .failed || writer.status == .cancelled || reader.status == .failed {
            complete(writer.error ?? reader.error ?? failure())
        } else if DispatchTime.now().uptimeNanoseconds &- lastProgress >= Self.noProgressNanoseconds {
            complete(HighFidelityMeetingCaptureError.finalMediaValidationFailed(
                "meeting compression made no progress for 60 seconds"))
        }
    }

    private func finish(_ index: Int) {
        guard continuation != nil, ended.insert(index).inserted else { return }
        channels[index].input.markAsFinished()
        remaining -= 1
        lastProgress = DispatchTime.now().uptimeNanoseconds
        guard remaining == 0 else { return }
        guard reader.status == .completed, writer.status == .writing else {
            complete(reader.error ?? writer.error ?? failure()); return
        }
        writer.endSession(atSourceTime: duration)
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard continuation != nil else { return }
                complete(writer.status == .completed ? nil : writer.error ?? failure())
            }
        }
    }

    private func complete(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        watchdog = nil
        if let error {
            // These reader/writer cancellation APIs are synchronous. Unlike an
            // AVAssetExportSession cancellation callback, no callback is used as
            // proof of completion. Each attempt also owns a unique directory;
            // an abandoned native path can never collide with a later retry.
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func failure() -> Error {
        HighFidelityMeetingCaptureError.finalMediaValidationFailed("meeting compression did not complete")
    }
}
#endif
