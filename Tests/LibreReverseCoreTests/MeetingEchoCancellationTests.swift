#if os(macOS)
@preconcurrency import AVFoundation
import XCTest
@testable import LibreReverseCore

final class MeetingEchoCancellationTests: XCTestCase {
    private let rate = 48_000
    private func runtime() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = root.appendingPathComponent(".artifacts/speech/libLibreReverseSpeech.dylib")
        guard FileManager.default.fileExists(atPath: result.path) else { throw XCTSkip("Prepare the standalone speech runtime") }
        return result
    }

    func testDelayedReverberantEchoAndDoubleTalkThroughTheProductionDecoder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try runtime()
        let count = rate * 18 + 137 // Exercise the final partial 10 ms frame.
        let far = voicedSignal(count: count, seed: 19)
        let near = voicedSignal(count: count, seed: 137).enumerated().map {
            (8 * rate..<15 * rate).contains($0.offset) ? $0.element * 0.6 : 0
        }
        let farURL = root.appendingPathComponent("speakers.caf")
        let cleanURL = root.appendingPathComponent("near.caf")
        let cleanOutput = root.appendingPathComponent("clean.caf")
        try write(far, to: farURL, stereoOpposite: true)
        try write(near, to: cleanURL)
        _ = try await MeetingSpeechAudioProcessor.process(microphoneURL: cleanURL, referenceURL: nil, destination: cleanOutput, libraryURL: library)
        let expected = try read(cleanOutput)
        // Negative delay represents a capture/reference timestamp offset. The
        // same production lookahead must support it without moving the voice.
        for delay in [-40, 60, 220] {
            let microphone = (0..<count).map { index -> Float in
                var value = near[index]
                for (offset, gain) in [(delay * 48, Float(0.35)), (delay * 48 + 336, Float(0.12)), (delay * 48 + 1104, Float(0.04))] {
                    let source = index - offset
                    if far.indices.contains(source) { value += far[source] * gain }
                }
                return value
            }
            let inputURL = root.appendingPathComponent("mic-\(delay).caf")
            let outputURL = root.appendingPathComponent("out-\(delay).caf")
            try write(microphone, to: inputURL)
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await MeetingSpeechAudioProcessor.process(microphoneURL: inputURL, referenceURL: farURL, destination: outputURL, libraryURL: library)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let actual = try read(outputURL)
            XCTAssertEqual(actual.count, count, "AEC must not add lookahead to the file or truncate its tail")
            XCTAssertTrue(actual.allSatisfy { $0.isFinite && abs($0) < 1 })
            let echoRange = (5 * rate)..<(7 * rate)
            let reduction = 20 * log10(rms(microphone, echoRange) / max(1e-12, rms(actual, echoRange)))
            XCTAssertGreaterThan(reduction, 15, "Echo attenuation at \(delay) ms")
            let correlation = correlation(expected, actual, range: (10 * rate)..<(14 * rate))
            XCTAssertGreaterThan(correlation, 0.65, "Independent near-end voice must survive double talk")
            print(String(format: "AEC production path: delay=%d ms echo=%.1f dB voiceCorrelation=%.3f elapsed=%.3f s for 18 s", delay, reduction, correlation, elapsed))
        }
    }

    func testHeadphonesAndSilentReferencePreserveNearEndSpeech() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try runtime()
        let near = voicedSignal(count: rate * 12, seed: 31)
        let nearURL = root.appendingPathComponent("near.caf")
        let referenceURL = root.appendingPathComponent("reference.caf")
        let baselineURL = root.appendingPathComponent("baseline.caf")
        try write(near, to: nearURL)
        _ = try await MeetingSpeechAudioProcessor.process(microphoneURL: nearURL, referenceURL: nil, destination: baselineURL, libraryURL: library)
        let baseline = try read(baselineURL)
        for silent in [false, true] {
            try? FileManager.default.removeItem(at: referenceURL)
            try write(silent ? [Float](repeating: 0, count: near.count) : voicedSignal(count: near.count, seed: 83), to: referenceURL, stereoOpposite: false)
            let output = root.appendingPathComponent("headphones-\(silent).caf")
            _ = try await MeetingSpeechAudioProcessor.process(microphoneURL: nearURL, referenceURL: referenceURL, destination: output, libraryURL: library)
            let actual = try read(output)
            XCTAssertEqual(actual.count, near.count)
            XCTAssertGreaterThan(correlation(baseline, actual, range: (4 * rate)..<(10 * rate)), 0.85)
            let levelChange = 20 * log10(rms(actual, (4 * rate)..<(10 * rate)) / rms(baseline, (4 * rate)..<(10 * rate)))
            XCTAssertGreaterThan(levelChange, -4, "Do not suppress a voice that has no acoustic echo")
        }
    }

    func testReferenceTimestampGapsDoNotCollapse() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try write([Float](repeating: 0.2, count: rate), to: source, stereoOpposite: true)
        let asset = AVURLAsset(url: source)
        let original = try await asset.loadTracks(withMediaType: .audio).first!
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let piece = CMTimeRange(start: .zero, duration: CMTime(value: 4800, timescale: 48_000))
        for start in [1237, 18017] {
            try track.insertTimeRange(piece, of: original, at: CMTime(value: Int64(start), timescale: 48_000))
        }
        let reader = try MeetingAudioTimelineReader(asset: composition, track: track, channels: 2)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        for start in stride(from: 0, to: 24_000, by: 480) {
            try reader.read(into: buffer, at: Int64(start))
            for i in 0..<480 {
                let frame = start + i
                let expected: Float = (1237..<6037).contains(frame) || (18017..<22817).contains(frame) ? 0.2 : 0
                XCTAssertEqual(buffer.floatChannelData![0][i], expected, accuracy: 0.0001)
                XCTAssertEqual(buffer.floatChannelData![1][i], -expected, accuracy: 0.0001)
            }
        }
    }

    func testReferenceValidation() async throws {
        let processor = try MeetingSpeechProcessor(libraryURL: runtime(), echoCancellation: true)
        var left = [Float](repeating: 0, count: 480)
        var right = left
        left[5] = .infinity
        XCTAssertThrowsError(try left.withUnsafeMutableBufferPointer { l in
            try right.withUnsafeMutableBufferPointer { r in try processor.analyzeReference(left: l.baseAddress!, right: r.baseAddress!, count: 480) }
        })
    }

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-aec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    /// Deterministic independent voiced signals with changing pitch, syllable
    /// envelopes, harmonics, and breath noise; a stationary tone is too easy
    /// for an echo filter and does not exercise double-talk behavior.
    private func voicedSignal(count: Int, seed: UInt64) -> [Float] {
        var random = seed
        var phase = 0.0
        var noise = 0.0
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            random = random &* 6364136223846793005 &+ 1
            noise = noise * 0.75 + (Double(random >> 32) / Double(UInt32.max) - 0.5) * 0.25
            let pitch = 110 + Double(seed % 79) + 27 * sin(t * (0.91 + Double(seed) / 100)) + 11 * sin(t * 4.7)
            phase += pitch * 2 * .pi / Double(rate)
            let syllable = max(0, sin(t * (12 + Double(seed % 7)) + Double(seed)))
            let envelope = 0.05 + 0.95 * syllable * syllable
            var voice = 0.0
            for harmonic in 1...7 { voice += sin(phase * Double(harmonic)) / Double(harmonic) }
            result[i] = Float((voice * 0.16 + noise * 0.03) * envelope)
        }
        return result
    }
    private func write(_ samples: [Float], to url: URL, stereoOpposite: Bool? = nil) throws {
        let channels: AVAudioChannelCount = stereoOpposite == nil ? 1 : 2
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        for start in stride(from: 0, to: samples.count, by: 4096) {
            let n = min(4096, samples.count - start)
            buffer.frameLength = AVAudioFrameCount(n)
            for channel in 0..<Int(channels) {
                for i in 0..<n { buffer.floatChannelData![channel][i] = samples[start + i] * (channel == 1 && stereoOpposite == true ? -1 : 1) }
            }
            try file.write(from: buffer)
        }
    }
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var result: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw SpeechError.invalid("Test audio ended before its declared length") }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return result
    }
    private func rms(_ samples: [Float], _ range: Range<Int>) -> Double {
        sqrt(range.reduce(0) { $0 + Double(samples[$1]) * Double(samples[$1]) } / Double(range.count))
    }
    private func correlation(_ expected: [Float], _ actual: [Float], range: Range<Int>) -> Double {
        // AEC and its filter bank have a small algorithmic delay. Search up to
        // 20 ms, never the simulated room delay or the 100 ms reference lookahead.
        var best = 0.0
        for lag in stride(from: 0, through: 960, by: 16) {
            var dot = 0.0, xx = 0.0, yy = 0.0
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 16) {
                let x = Double(expected[i]), y = Double(actual[i + lag])
                dot += x * y; xx += x * x; yy += y * y
            }
            best = max(best, dot / max(1e-20, sqrt(xx * yy)))
        }
        return best
    }
}
#endif
