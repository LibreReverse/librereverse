#if os(macOS)
import AVFoundation
import CSpeech
import Darwin
import Foundation

/// Standalone WebRTC APM. This object never owns an audio device or output node.
final class MeetingSpeechProcessor {
    static var bundledLibraryURL: URL? {
        if let path = Bundle.main.privateFrameworksPath {
            let url = URL(fileURLWithPath: path).appendingPathComponent("libLibreReverseSpeech.dylib")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LIBREREVERSE_SPEECH_RUNTIME"] {
            return URL(fileURLWithPath: path).appendingPathComponent("libLibreReverseSpeech.dylib")
        }
        #endif
        return nil
    }

    private let instance: OpaquePointer
    init(libraryURL: URL, echoCancellation: Bool = false) throws {
        guard let instance = lr_speech_open(libraryURL.path, echoCancellation ? 1 : 0) else {
            throw SpeechError.invalid("WebRTC microphone processor could not be loaded")
        }
        self.instance = instance
    }
    deinit { lr_speech_close(instance) }
    func analyzeReference(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) throws {
        guard count == 480, lr_speech_reference(instance, left, right, Int32(count)) == 0 else {
            throw SpeechError.invalid("WebRTC rejected an echo reference frame")
        }
    }
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int) throws {
        guard count == 480, lr_speech_frame(instance, samples, Int32(count)) == 0 else {
            throw SpeechError.invalid("WebRTC rejected a microphone frame")
        }
    }
}

enum SpeechError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Retains the two original audio sources for post-capture microphone processing.
/// The native MP4 is always the recoverable fallback. All appends run on the
/// capture sample queue; optional enhancement must never stall that queue.
final class MeetingSpeechCapture: @unchecked Sendable {
    struct Metadata: Codable {
        var version = 1
        var systemAudio: Bool
        var ready = false
        var enhanced = false
        var systemPeak: Double = 1
        var failure: String?
        var processingSeconds: Double?
        var echoCancellation: Bool?
    }
    static func sidecar(_ movie: URL, _ suffix: String) -> URL {
        movie.deletingLastPathComponent().appendingPathComponent(movie.lastPathComponent + ".speech-" + suffix)
    }
    private final class Source {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        init(url: URL, channels: Int) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw SpeechError.invalid("Separate audio writer is unavailable") }
            writer.add(input)
        }
        func start(at time: CMTime) throws {
            guard writer.startWriting() else { throw writer.error ?? SpeechError.invalid("Audio writer did not start") }
            writer.startSession(atSourceTime: time)
        }
        func append(_ sample: CMSampleBuffer) throws {
            guard input.isReadyForMoreMediaData, input.append(sample) else {
                throw writer.error ?? SpeechError.invalid("Separate audio writer could not keep up")
            }
        }
        func finish() async throws {
            guard writer.status == .writing else { throw SpeechError.invalid("Separate audio never started") }
            input.markAsFinished()
            let latch = MeetingCaptureFinishLatch()
            writer.finishWriting { latch.finish() }
            guard await latch.wait(timeoutSeconds: 30), writer.status == .completed else {
                writer.cancelWriting()
                throw writer.error ?? SpeechError.invalid("Separate audio did not finish")
            }
        }
    }
    private let movie: URL
    private let microphone: Source
    private let system: Source?
    private var origin: CMTime?
    private var accepting = true
    private var metadata: Metadata

    init(movie: URL, systemAudio: Bool) throws {
        self.movie = movie
        microphone = try Source(url: Self.sidecar(movie, "mic.mov"), channels: 1)
        system = systemAudio ? try Source(url: Self.sidecar(movie, "system.mov"), channels: 2) : nil
        metadata = Metadata(systemAudio: systemAudio, systemPeak: 0)
        try saveMetadata()
    }
    func startVideo(at time: CMTime) {
        guard accepting, origin == nil, metadata.failure == nil, time.isValid, time.seconds.isFinite else { return }
        do {
            try microphone.start(at: time)
            try system?.start(at: time)
            origin = time
        } catch { fail(error) }
    }
    func append(_ sample: CMSampleBuffer, microphone isMicrophone: Bool, peakAbsolute: Double? = nil) {
        guard accepting, metadata.failure == nil, let origin,
              sample.presentationTimeStamp >= origin else { return }
        if !isMicrophone {
            // Missing metering must reserve full-scale headroom, not imply
            // silence. Meter the original callback once, before serialization.
            let peak = peakAbsolute.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 1
            metadata.systemPeak = max(metadata.systemPeak, peak)
        }
        do { try (isMicrophone ? microphone : system)?.append(sample) }
        catch { fail(error) }
    }
    func endSamples() { accepting = false }
    private func fail(_ error: Error) {
        FileHandle.standardError.write(Data("Separate meeting audio unavailable; keeping native recording: \(error.localizedDescription)\n".utf8))
        metadata.failure = error.localizedDescription
        microphone.writer.cancelWriting()
        system?.writer.cancelWriting()
        try? saveMetadata()
    }
    private func saveMetadata() throws {
        try JSONEncoder().encode(metadata).write(to: Self.sidecar(movie, "json"), options: .atomic)
    }
    /// Called after the sample queue has drained and will receive no new audio.
    func finish() async {
        guard metadata.failure == nil else { return }
        do {
            try await microphone.finish()
            try await system?.finish()
            metadata.ready = true
            try saveMetadata()
        } catch { fail(error) }
    }

    /// A failed enhancement never discards a valid native movie. Recovery can
    /// retry a ready sidecar; replacing the MP4 is atomic and idempotent because
    /// its existing audio is discarded, not processed for a second time.
    @discardableResult
    static func enhanceIfReady(movie: URL, libraryURL: URL? = MeetingSpeechProcessor.bundledLibraryURL) async -> Bool {
        let metadataURL = sidecar(movie, "json")
        guard let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.version == 1, metadata.ready, !metadata.enhanced,
              metadata.failure == nil else { return false }
        guard let libraryURL else {
            FileHandle.standardError.write(Data("Meeting microphone enhancement unavailable; keeping original audio.\n".utf8))
            return false
        }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            try await MeetingSpeechFinalizer.enhance(movie: movie, metadata: metadata, libraryURL: libraryURL)
            metadata.processingSeconds = ProcessInfo.processInfo.systemUptime - started
            metadata.enhanced = true
            metadata.echoCancellation = metadata.systemAudio && metadata.systemPeak > 0
            FileHandle.standardError.write(Data(String(format: "Meeting microphone enhanced with WebRTC in %.3f seconds (AEC %@).\n", metadata.processingSeconds ?? 0, metadata.echoCancellation == true ? "on" : "off: no playback reference").utf8))
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("Meeting microphone enhancement failed; keeping playable audio: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

private enum MeetingSpeechFinalizer {
    static func enhance(movie: URL, metadata: MeetingSpeechCapture.Metadata, libraryURL: URL) async throws {
        let microphoneURL = MeetingSpeechCapture.sidecar(movie, "mic.mov")
        let pcmURL = MeetingSpeechCapture.sidecar(movie, "processed.caf")
        let mixedURL = MeetingSpeechCapture.sidecar(movie, "mixed.m4a")
        let outputURL = MeetingSpeechCapture.sidecar(movie, "final.mp4")
        let temporary = [pcmURL, mixedURL, outputURL]
        for url in temporary where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        try Task.checkCancellation()
        // If the whole system track is known to be silent, skip AEC's FFTs
        // and its extra decode pass. Unknown metering reserves a peak of one.
        let referenceURL = metadata.systemAudio && metadata.systemPeak > 0
            ? MeetingSpeechCapture.sidecar(movie, "system.mov") : nil
        let microphonePeak = try await MeetingSpeechAudioProcessor.process(
            microphoneURL: microphoneURL, referenceURL: referenceURL,
            destination: pcmURL, libraryURL: libraryURL)
        try Task.checkCancellation()

        let original = AVURLAsset(url: movie)
        let duration = try await original.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw SpeechError.invalid("Movie duration is invalid") }
        let audio = AVMutableComposition()
        audio.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: duration))
        let gain = Float(min(1, 0.891251 / max(0.891251, microphonePeak + (metadata.systemAudio ? metadata.systemPeak : 0))))
        var parameters: [AVAudioMixInputParameters] = []
        func addAudio(_ asset: AVAsset) async throws {
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = audio.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw SpeechError.invalid("Separate audio track is missing")
            }
            let range = try await source.load(.timeRange)
            let end = CMTimeMinimum(range.end, duration)
            guard end > range.start else { throw SpeechError.invalid("Separate audio falls outside the movie") }
            try target.insertTimeRange(CMTimeRange(start: range.start, end: end), of: source, at: range.start)
            let input = AVMutableAudioMixInputParameters(track: target)
            input.setVolume(gain, at: .zero)
            parameters.append(input)
        }
        try await addAudio(AVURLAsset(url: pcmURL))
        if metadata.systemAudio {
            try await addAudio(AVURLAsset(url: MeetingSpeechCapture.sidecar(movie, "system.mov")))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        guard let audioExport = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechError.invalid("Audio mix export is unavailable")
        }
        audioExport.audioMix = mix
        audioExport.timeRange = CMTimeRange(start: .zero, duration: duration)
        // The native async API handles Task cancellation itself. Calling
        // cancelExport concurrently with setup can crash AVFoundation.
        try await audioExport.export(to: mixedURL, as: .m4a)
        try Task.checkCancellation()
        let final = AVMutableComposition()
        guard let video = try await original.loadTracks(withMediaType: .video).first,
              let finalVideo = final.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SpeechError.invalid("Original video is missing")
        }
        let videoRange = try await video.load(.timeRange)
        try finalVideo.insertTimeRange(videoRange, of: video, at: videoRange.start)
        finalVideo.preferredTransform = try await video.load(.preferredTransform)
        let encodedAudio = AVURLAsset(url: mixedURL)
        guard let sourceAudio = try await encodedAudio.loadTracks(withMediaType: .audio).first,
              let finalAudio = final.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SpeechError.invalid("Processed audio is missing")
        }
        let audioRange = try await sourceAudio.load(.timeRange)
        try finalAudio.insertTimeRange(audioRange, of: sourceAudio, at: audioRange.start)
        guard let export = AVAssetExportSession(asset: final, presetName: AVAssetExportPresetPassthrough) else {
            throw SpeechError.invalid("Video passthrough is unavailable")
        }
        export.metadata = try await original.load(.metadata)
        try await export.export(to: outputURL, as: .mp4)
        let size = try await video.load(.naturalSize).applying(finalVideo.preferredTransform)
        let evidence = try await HighFidelityMeetingCaptureMediaInspector.inspect(
            url: outputURL, expectedWidth: Int(abs(size.width).rounded()), expectedHeight: Int(abs(size.height).rounded()), requiresAudio: true)
        guard abs(evidence.durationSeconds - duration.seconds) < 0.1 else {
            throw SpeechError.invalid("Processed movie duration changed")
        }
        try Task.checkCancellation()
        guard rename(outputURL.path, movie.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

}

/// A forward-only decoder on the common capture clock. Retains one decoded
/// packet and fixed scratch buffers; gaps become silence without shifting time.
final class MeetingAudioTimelineReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let channels: Int
    private let scratch: UnsafeMutablePointer<Float>
    private var pending: CMSampleBuffer?
    private var pendingStart: Int64 = 0
    private var pendingEnd: Int64 = 0
    private var nextFrame: Int64 = 0
    private var ended = false

    init(asset: AVAsset, track: AVAssetTrack, channels: Int) throws {
        guard channels == 1 || channels == 2 else { throw SpeechError.invalid("Unsupported reference channel count") }
        self.channels = channels
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SpeechError.invalid("Meeting audio decoder is unavailable") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SpeechError.invalid("Meeting audio decoding failed") }
        scratch = .allocate(capacity: 480 * channels)
    }
    deinit { reader.cancelReading(); scratch.deallocate() }

    func read(into buffer: AVAudioPCMBuffer, at start: Int64, count: Int = 480) throws {
        guard count > 0, count <= 480, start >= nextFrame,
              buffer.frameCapacity >= 480, Int(buffer.format.channelCount) == channels,
              let planes = buffer.floatChannelData else { throw SpeechError.invalid("Invalid audio frame request") }
        for channel in 0..<channels { planes[channel].update(repeating: 0, count: 480) }
        buffer.frameLength = AVAudioFrameCount(count)
        let end = start + Int64(count)
        while !ended {
            if pending == nil {
                guard let sample = output.copyNextSampleBuffer() else {
                    guard reader.status == .completed else { throw reader.error ?? SpeechError.invalid("Meeting audio decoding was incomplete") }
                    ended = true
                    break
                }
                if sample.numSamples == 0 { continue }
                let seconds = sample.presentationTimeStamp.seconds
                guard seconds.isFinite, seconds >= 0, seconds < 86_400,
                      let data = sample.dataBuffer,
                      CMBlockBufferGetDataLength(data) == sample.numSamples * channels * 4 else {
                    throw SpeechError.invalid("Meeting audio has invalid PCM or timestamps")
                }
                pending = sample
                pendingStart = Int64((seconds * 48_000).rounded())
                pendingEnd = pendingStart + Int64(sample.numSamples)
            }
            if pendingEnd <= start { pending = nil; continue }
            if pendingStart >= end { break }
            let overlapStart = max(start, pendingStart)
            let overlapEnd = min(end, pendingEnd)
            let frames = Int(overlapEnd - overlapStart)
            let offset = Int(overlapStart - start)
            guard let block = pending?.dataBuffer,
                  CMBlockBufferCopyDataBytes(block, atOffset: Int(overlapStart - pendingStart) * channels * 4,
                                             dataLength: frames * channels * 4, destination: scratch) == kCMBlockBufferNoErr else {
                throw SpeechError.invalid("Meeting audio sample could not be copied")
            }
            for channel in 0..<channels {
                for index in 0..<frames { planes[channel][offset + index] = scratch[index * channels + channel] }
            }
            if pendingEnd <= end { pending = nil } else { break }
        }
        nextFrame = end
    }
}

/// Offline AEC keeps one render and one capture frame in flight. A short render
/// lookahead also accommodates device timestamp offsets where the reference
/// would otherwise arrive after its echo. Only priming output is discarded;
/// the recorded microphone's timestamps and frame count are unchanged.
enum MeetingSpeechAudioProcessor {
    static let referenceLookaheadFrames = 4_800 // 100 ms at 48 kHz.

    static func process(microphoneURL: URL, referenceURL: URL?, destination: URL, libraryURL: URL) async throws -> Double {
        let microphone = AVURLAsset(url: microphoneURL)
        guard let track = try await microphone.loadTracks(withMediaType: .audio).first else {
            throw SpeechError.invalid("Separate microphone track is missing")
        }
        let reference = referenceURL.map { AVURLAsset(url: $0) }
        let referenceTrack = try await reference?.loadTracks(withMediaType: .audio).first
        if reference != nil, referenceTrack == nil { throw SpeechError.invalid("Echo reference track is missing") }
        let duration = try await track.load(.timeRange).end.seconds
        guard duration.isFinite, duration > 0, duration < 86_400 else { throw SpeechError.invalid("Microphone duration is invalid") }
        let frameCount = Int64((duration * 48_000).rounded())
        let task = Task.detached(priority: .utility) {
            let mic = try MeetingAudioTimelineReader(asset: microphone, track: track, channels: 1)
            var render: MeetingAudioTimelineReader?
            if let reference, let referenceTrack {
                render = try MeetingAudioTimelineReader(asset: reference, track: referenceTrack, channels: 2)
            }
            let processor = try MeetingSpeechProcessor(libraryURL: libraryURL, echoCancellation: render != nil)
            let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let captureBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 480)!
            let renderBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480)!
            let samples = captureBuffer.floatChannelData![0]
            let file = try AVAudioFile(forWriting: destination, settings: mono.settings)
            // Async task completion does not guarantee autoreleased audio-file
            // internals have flushed. Close before the muxer opens this CAF.
            defer { file.close() }
            let lookahead = render == nil ? 0 : Int64(referenceLookaheadFrames)
            var position = -lookahead
            var peak = 0.0
            while position < frameCount {
                try Task.checkCancellation()
                if let render {
                    try render.read(into: renderBuffer, at: position + lookahead)
                    try processor.analyzeReference(left: renderBuffer.floatChannelData![0], right: renderBuffer.floatChannelData![1], count: 480)
                }
                let count = position < 0 ? 480 : min(480, Int(frameCount - position))
                if position < 0 { samples.update(repeating: 0, count: 480) }
                else { try mic.read(into: captureBuffer, at: position, count: count) }
                try processor.process(samples, count: 480)
                if position >= 0 {
                    for index in 0..<count {
                        guard samples[index].isFinite else { throw SpeechError.invalid("Processed audio is not finite") }
                        peak = max(peak, Double(abs(samples[index])))
                    }
                    captureBuffer.frameLength = AVAudioFrameCount(count)
                    try file.write(from: captureBuffer)
                }
                position += 480
            }
            return peak
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}
#endif
