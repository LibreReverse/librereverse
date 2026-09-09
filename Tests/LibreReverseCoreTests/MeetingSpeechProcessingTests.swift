#if os(macOS)
@preconcurrency import AVFoundation
import XCTest
@testable import LibreReverseCore

final class MeetingSpeechProcessingTests: XCTestCase {
    private func runtime() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".artifacts/speech/libLibreReverseSpeech.dylib")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare the standalone speech runtime to exercise its native DSP") }
        return url
    }
    func testSparseCaptureWaitsForNativeFinishButNotAudioEnhancement() {
        XCTAssertFalse(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: true, hasMeetingOperation: true, nativeRecordingFinished: false))
        XCTAssertFalse(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: true, hasMeetingOperation: true, nativeRecordingFinished: false, allowMeetingOperation: true))
        XCTAssertTrue(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: true, hasMeetingOperation: true, nativeRecordingFinished: true))
        XCTAssertTrue(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: false, hasMeetingOperation: false, nativeRecordingFinished: false))
        XCTAssertFalse(MeetingCaptureFinalizationPolicy.allowsSparseCapture(
            hasMeetingSession: false, hasMeetingOperation: true, nativeRecordingFinished: false))
    }
    func testProcessorRejectsInvalidFramesAndKeepsSilenceSilent() throws {
        XCTAssertThrowsError(try MeetingSpeechProcessor(libraryURL: URL(fileURLWithPath: "/nonexistent/speech.dylib")))
        let processor = try MeetingSpeechProcessor(libraryURL: runtime())
        var samples = [Float](repeating: 0, count: 480)
        try samples.withUnsafeMutableBufferPointer { buffer in
            XCTAssertThrowsError(try processor.process(buffer.baseAddress!, count: 479))
            for _ in 0..<100 { try processor.process(buffer.baseAddress!, count: 480) }
            XCTAssertLessThan(buffer.map(abs).max()!, 0.00001)
            buffer[20] = .nan
            XCTAssertThrowsError(try processor.process(buffer.baseAddress!, count: 480))
        }
    }
    func testEnhancementPreservesVideoAndDelayedAudioAndIsIdempotent() async throws {
        let library = try runtime()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("meeting.mp4")
        try await video(at: movie)
        let originalPackets = try await videoPackets(movie)
        let capture = try MeetingSpeechCapture(movie: movie, systemAudio: true)
        let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
        capture.startVideo(at: origin)
        // Input starts late and uses a different sample rate, just as a USB or
        // Bluetooth microphone can. Remote audio occupies a separate interval.
        let mic = root.appendingPathComponent("mic.caf")
        let system = root.appendingPathComponent("system.caf")
        try tone(at: mic, rate: 44_100, channels: 1, frequency: 220, amplitude: 0.025, active: 0.1..<0.6)
        try tone(at: system, rate: 48_000, channels: 2, frequency: 880, amplitude: 0.12, active: 1.0..<1.4)
        try await feed(mic, capture: capture, microphone: true, offset: origin + CMTime(seconds: 0.25, preferredTimescale: 48_000))
        try await feed(system, capture: capture, microphone: false, offset: origin)
        capture.endSamples()
        await capture.finish()
        let metadataURL = MeetingSpeechCapture.sidecar(movie, "json")
        let metadata = try JSONDecoder().decode(MeetingSpeechCapture.Metadata.self, from: Data(contentsOf: metadataURL))
        XCTAssertTrue(metadata.ready, metadata.failure ?? "not ready")
        let beforeCancellation = try Data(contentsOf: movie)
        let cancelled = Task { await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: library) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(try Data(contentsOf: movie), beforeCancellation)
        let enhanced = await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: library)
        XCTAssertTrue(enhanced)
        let packets = try await videoPackets(movie)
        XCTAssertEqual(packets, originalPackets, "Video packets must be copied without re-encoding")
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "Playback and transcription must hear the same single mix")
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.06)
        let normalized = root.appendingPathComponent("decoded.wav")
        try await MeetingAudioPCMExporter.export16kMonoWAV(from: movie, to: normalized)
        let audio = try AVAudioFile(forReading: normalized)
        XCTAssertLessThan(try rms(audio, 0..<0.2), 0.001, "Delayed mic must not move to zero")
        XCTAssertGreaterThan(try rms(audio, 0.45..<0.7), 0.01)
        XCTAssertGreaterThan(try rms(audio, 1.1..<1.3), 0.03, "Remote participant must remain audible")
        let bytes = try Data(contentsOf: movie)
        let repeated = await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: library)
        XCTAssertFalse(repeated)
        XCTAssertEqual(try Data(contentsOf: movie), bytes)
        // Simulate replacement succeeding just before the completion marker was
        // written. Recovery still uses the original sidecars, never the old mix.
        var interrupted = metadata
        interrupted.enhanced = false
        try JSONEncoder().encode(interrupted).write(to: metadataURL)
        let recovered = await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: library)
        XCTAssertTrue(recovered)
        let recoveredPackets = try await videoPackets(movie)
        XCTAssertEqual(recoveredPackets, originalPackets)
    }
    func testMissingProcessorAndBrokenSidecarPreserveOriginalRecording() async throws {
        let library = try runtime()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("meeting.mp4")
        try await video(at: movie)
        let original = try Data(contentsOf: movie)
        var metadata = MeetingSpeechCapture.Metadata(systemAudio: false)
        metadata.ready = true
        try JSONEncoder().encode(metadata).write(to: MeetingSpeechCapture.sidecar(movie, "json"))
        let missing = await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: root.appendingPathComponent("missing.dylib"))
        XCTAssertFalse(missing)
        XCTAssertEqual(try Data(contentsOf: movie), original)
        let corrupt = await MeetingSpeechCapture.enhanceIfReady(movie: movie, libraryURL: library)
        XCTAssertFalse(corrupt)
        XCTAssertEqual(try Data(contentsOf: movie), original)
    }
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func tone(at url: URL, rate: Double, channels: AVAudioChannelCount, frequency: Double, amplitude: Float, active: Range<Double>) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = Int(rate * 1.503)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for i in 0..<count {
                let t = Double(i) / rate
                buffer.floatChannelData![channel][i] = active.contains(t) ? amplitude * Float(sin(t * frequency * 2 * .pi)) : 0
            }
        }
        try file.write(from: buffer)
    }
    private func feed(_ url: URL, capture: MeetingSpeechCapture, microphone: Bool, offset: CMTime) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            var timing = CMSampleTimingInfo(duration: CMTimeMultiplyByFloat64(sample.duration, multiplier: 1 / Double(sample.numSamples)), presentationTimeStamp: sample.presentationTimeStamp + offset, decodeTimeStamp: .invalid)
            var shifted: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted), noErr)
            capture.append(try XCTUnwrap(shifted), microphone: microphone)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.status, .completed)
    }
    private func rms(_ audio: AVAudioFile, _ range: Range<Double>) throws -> Double {
        let rate = audio.processingFormat.sampleRate
        audio.framePosition = AVAudioFramePosition(range.lowerBound * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount((range.upperBound - range.lowerBound) * rate))!
        try audio.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
    }
    private func videoPackets(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var packets: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let size = data.count
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            packets.append(data)
        }
        XCTAssertFalse(packets.isEmpty)
        return packets
    }
    private func video(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel), kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(pixel!, [])
            memset(CVPixelBufferGetBaseAddress(pixel!), Int32(frame * 10), CVPixelBufferGetBytesPerRow(pixel!) * 32)
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            XCTAssertTrue(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
#endif
