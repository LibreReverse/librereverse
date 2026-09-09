#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation

/// Compact peak envelope in recording-relative seconds. Zero means silence, not
/// missing media. Values are linear absolute amplitudes; presentation may apply
/// a perceptual curve without changing the cached audio evidence.
public struct MeetingWaveformEnvelope: Codable, Equatable, Sendable {
    public let duration: TimeInterval
    public let binDuration: TimeInterval
    public let peaks: Data

    public init(duration: TimeInterval, binDuration: TimeInterval, peaks: Data) {
        self.duration = duration
        self.binDuration = binDuration
        self.peaks = peaks
    }

    public struct Part: Sendable {
        public let envelope: MeetingWaveformEnvelope
        public let startOffset: TimeInterval

        /// Start of the source media, relative to the displayed meeting span.
        public init(envelope: MeetingWaveformEnvelope, startOffset: TimeInterval) {
            self.envelope = envelope
            self.startOffset = startOffset
        }
    }

    /// Coalesced meeting segments can span several recordings. Retain their
    /// actual media origins, silence gaps and overlap peaks in one display axis.
    public static func combining(_ parts: [Part], duration: TimeInterval) -> Self {
        guard duration.isFinite, duration > 0 else {
            return .init(duration: 0, binDuration: 0.1, peaks: Data())
        }
        let binDuration = max(0.1, duration / Double(MeetingWaveformAccumulator.maximumBins))
        var peaks = [UInt8](repeating: 0, count: min(MeetingWaveformAccumulator.maximumBins,
            max(1, Int(ceil(duration / binDuration)))))
        for part in parts {
            let source = part.envelope
            guard part.startOffset.isFinite, source.binDuration.isFinite,
                source.binDuration > 0, source.duration.isFinite, source.duration > 0 else { continue }
            for (index, peak) in source.peaks.enumerated() where peak > 0 {
                let start = part.startOffset + Double(index) * source.binDuration
                let end = part.startOffset + min(source.duration, Double(index + 1) * source.binDuration)
                guard start < duration, end > 0, start < end else { continue }
                // Remove sub-nanosecond floating-point error at shared bin
                // edges, without smearing a preceding peak into quiet bins.
                let first = Int(min(Double(peaks.count - 1), floor(max(0, start) / binDuration + 1e-8)))
                let last = Int(min(Double(peaks.count), ceil(min(duration, end) / binDuration - 1e-8)))
                for target in first..<max(first, last) { peaks[target] = max(peaks[target], peak) }
            }
        }
        return .init(duration: duration, binDuration: binDuration, peaks: Data(peaks))
    }

    public func amplitude(at seconds: TimeInterval) -> Float {
        guard seconds.isFinite, seconds >= 0, seconds < duration,
            binDuration.isFinite, binDuration > 0, !peaks.isEmpty else { return 0 }
        let index = min(peaks.count - 1, Int(min(Double(peaks.count - 1), seconds / binDuration)))
        return Float(peaks[index]) / 255
    }

    /// Maximum over the half-open interval, so narrow speech transients survive
    /// zooming out. Query in media time, never compressed timeline coordinates.
    public func peak(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard start.isFinite, end.isFinite, start < end, end > 0, start < duration,
            binDuration.isFinite, binDuration > 0, !peaks.isEmpty else { return 0 }
        let first = Int(min(Double(peaks.count - 1), max(0, start) / binDuration))
        let last = Int(min(Double(peaks.count), ceil(min(duration, end) / binDuration)))
        guard first < last else { return 0 }
        return Float(peaks[first..<last].max() ?? 0) / 255
    }
}

/// Reads embedded metadata only. No playback/timeline request can decode audio,
/// hydrate an archive, or fetch a remote URL. The small memory working set is
/// invalidated when the underlying recording identity changes.
public actor MeetingWaveformCache {
    public static let shared = MeetingWaveformCache()
    private let legacyIndexDirectory: URL?
    private var memory: [String: MeetingWaveformEnvelope] = [:]
    private var recency: [String] = []
    private var pending: [String: Task<MeetingWaveformEnvelope?, Never>] = [:]
    private var tail: Task<MeetingWaveformEnvelope?, Never>?

    public init(legacyIndexDirectory: URL? = nil) {
        self.legacyIndexDirectory = legacyIndexDirectory
    }

    public func envelope(forLocalMediaURL url: URL) async -> MeetingWaveformEnvelope? {
        guard !Task.isCancelled, let key = Self.identity(url) else { return nil }
        if let value = memory[key] {
            remember(value, key: key)
            return value
        }
        if let task = pending[key] {
            let value = await task.value
            return Task.isCancelled ? nil : value
        }
        let predecessor = tail
        let legacyIndexDirectory = legacyIndexDirectory
        let task = Task.detached(priority: .utility) { () -> MeetingWaveformEnvelope? in
            // Waiting suspends; it does not occupy a worker or spin.
            _ = await predecessor?.value
            guard !Task.isCancelled else { return nil }
            guard let value = try? MeetingWaveformMetadata.readAvailable(fromLocalMediaURL: url, directory: legacyIndexDirectory),
                !Task.isCancelled, Self.identity(url) == key else { return nil }
            return value
        }
        pending[key] = task
        tail = task
        let result = await task.value
        pending[key] = nil
        if pending.isEmpty { tail = nil }
        if let result { remember(result, key: key) }
        return Task.isCancelled ? nil : result
    }

    /// Call when discarding the owning library/window, not on every scrub. A
    /// cancelled caller alone does not cancel work shared by another caller.
    public func cancelAll() {
        for task in pending.values { task.cancel() }
    }

    private func remember(_ value: MeetingWaveformEnvelope, key: String) {
        memory[key] = value
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > 16 { memory[recency.removeFirst()] = nil }
    }

    private nonisolated static func identity(_ url: URL) -> String? {
        // Fresh stat values, not NSURL's cached resource properties: recordings
        // can be replaced at the same pathname after archive restoration.
        guard url.isFileURL,
            let values = try? FileManager.default.attributesOfItem(atPath: url.path),
            values[.type] as? FileAttributeType == .typeRegular,
            let size = values[.size] as? NSNumber,
            let modified = values[.modificationDate] as? Date else { return nil }
        let inode = (values[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let device = (values[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let identity = "v1|\(url.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)|\(device)|\(inode)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }


}

/// The accumulator reduces channels by absolute maximum before temporal peak
/// aggregation: opposite-phase microphone/system channels cannot cancel out.
struct MeetingWaveformAccumulator {
    static let maximumBins = 131_072
    let duration: TimeInterval
    let binDuration: TimeInterval
    private(set) var peaks: [UInt8]

    init(duration: TimeInterval) {
        self.duration = duration
        binDuration = max(0.1, duration / Double(Self.maximumBins))
        peaks = [UInt8](repeating: 0, count: min(Self.maximumBins, max(1, Int(ceil(duration / binDuration)))))
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double, startTime: Double) {
        guard channels > 0, sampleRate.isFinite, sampleRate > 0, startTime.isFinite else { return }
        let frames = samples.count / channels
        var frame = max(0, Int(min(Double(frames), ceil(-startTime * sampleRate))))
        while frame < frames {
            let time = startTime + Double(frame) / sampleRate
            guard time < duration else { break }
            let index = min(peaks.count - 1, max(0, Int(time / binDuration)))
            let boundary = (Double(index + 1) * binDuration - startTime) * sampleRate
            let end = min(frames, max(frame + 1, Int(min(Double(frames), ceil(boundary)))))
            var maximum: Float = 0
            for sample in samples[(frame * channels)..<(end * channels)] where sample.isFinite {
                maximum = max(maximum, abs(sample))
            }
            peaks[index] = max(peaks[index], UInt8((min(1, maximum) * 255).rounded()))
            frame = end
        }
    }

    var envelope: MeetingWaveformEnvelope {
        .init(duration: duration, binDuration: binDuration, peaks: Data(peaks))
    }
}

enum MeetingWaveformExtractor {
    static func extract(url: URL) async throws -> MeetingWaveformEnvelope {
        let options: [String: Any] = url.pathExtension.isEmpty
            ? ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"] : [:]
        let asset = AVURLAsset(url: url, options: options)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty { return .init(duration: duration, binDuration: 0.1, peaks: Data()) }
        var accumulator = MeetingWaveformAccumulator(duration: duration)
        // Tracks are decoded independently instead of mixed, retaining activity
        // even when channels or tracks have equal and opposite sample values.
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8_000,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CocoaError(.fileReadUnsupportedScheme) }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            var decodedSampleCount = 0
            while reader.status == .reading {
                try Task.checkCancellation()
                let consumed: Bool = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    guard let description = CMSampleBufferGetFormatDescription(sample),
                        let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                        let block = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
                    let length = CMBlockBufferGetDataLength(block)
                    decodedSampleCount += CMSampleBufferGetNumSamples(sample)
                    // AVAssetReader supplies packet-sized PCM buffers. Bound an
                    // unexpected decoder result rather than allocate a huge copy.
                    guard length <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                    var contiguousLength = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                        lengthAtOffsetOut: &contiguousLength, totalLengthOut: nil, dataPointerOut: &pointer)
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    func consume(_ raw: UnsafeRawPointer) {
                        accumulator.append(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: length / MemoryLayout<Float>.size),
                            channels: Int(format.mChannelsPerFrame), sampleRate: format.mSampleRate, startTime: time)
                    }
                    if status == noErr, contiguousLength == length, let pointer {
                        consume(UnsafeRawPointer(pointer))
                    } else {
                        let copy = UnsafeMutableRawPointer.allocate(byteCount: max(1, length), alignment: MemoryLayout<Float>.alignment)
                        defer { copy.deallocate() }
                        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: copy) == noErr else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        consume(UnsafeRawPointer(copy))
                    }
                    return true
                }
                if !consumed { break }
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            guard decodedSampleCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        return accumulator.envelope
    }
}
#endif
