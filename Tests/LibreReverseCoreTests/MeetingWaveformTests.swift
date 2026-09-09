#if os(macOS)
import Foundation
import AVFoundation
import XCTest
@testable import LibreReverseCore

final class MeetingWaveformTests: XCTestCase {
    func testPeakQueryPreservesTransientsAndClipsToRecording() {
        let envelope = MeetingWaveformEnvelope(duration: 0.5, binDuration: 0.1,
            peaks: Data([0, 0, 255, 0, 64]))
        XCTAssertEqual(envelope.peak(from: 0, to: 0.2), 0)
        XCTAssertEqual(envelope.peak(from: 0, to: 0.4), 1)
        XCTAssertEqual(envelope.peak(from: -10, to: 100), 1)
        XCTAssertEqual(envelope.peak(from: 0.5, to: 100), 0)
        XCTAssertEqual(envelope.amplitude(at: 0.25), 1)
        XCTAssertEqual(envelope.amplitude(at: 0.5), 0)
        XCTAssertEqual(envelope.peak(from: .nan, to: 1), 0)
    }

    func testAntiphaseChannelsDoNotCancelAndPacketTimesPreserveSilence() {
        var accumulator = MeetingWaveformAccumulator(duration: 1)
        let samples: [Float] = Array(repeating: [0.5, -0.5], count: 800).flatMap { $0 }
        samples.withUnsafeBufferPointer {
            accumulator.append($0, channels: 2, sampleRate: 8_000, startTime: 0.4)
        }
        let envelope = accumulator.envelope
        XCTAssertEqual(envelope.peak(from: 0, to: 0.4), 0)
        XCTAssertEqual(envelope.amplitude(at: 0.45), 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(envelope.peak(from: 0.5, to: 1), 0)
    }

    func testCompositionUsesMediaOriginsKeepsGapsAndCombinesOverlaps() {
        let first = MeetingWaveformEnvelope(duration: 0.4, binDuration: 0.1,
            peaks: Data([255, 128, 64, 32]))
        let second = MeetingWaveformEnvelope(duration: 0.2, binDuration: 0.1,
            peaks: Data([200, 100]))
        let combined = MeetingWaveformEnvelope.combining([
            .init(envelope: first, startOffset: -0.2),
            .init(envelope: second, startOffset: 0.5),
            .init(envelope: second, startOffset: 0.6),
        ], duration: 1)
        XCTAssertEqual(combined.amplitude(at: 0.05), 64.0 / 255, accuracy: 0.001)
        XCTAssertEqual(combined.amplitude(at: 0.15), 32.0 / 255, accuracy: 0.001)
        XCTAssertEqual(combined.peak(from: 0.3, to: 0.5), 0)
        XCTAssertEqual(combined.amplitude(at: 0.65), 200.0 / 255, accuracy: 0.001)
        XCTAssertEqual(combined.peak(from: 0.9, to: 1), 0)
        XCTAssertLessThanOrEqual(MeetingWaveformEnvelope.combining([
            .init(envelope: first, startOffset: 0),
        ], duration: 172_800).peaks.count, MeetingWaveformAccumulator.maximumBins)
    }

    func testMemoryIsBoundedForLongRecordings() {
        let accumulator = MeetingWaveformAccumulator(duration: 48 * 60 * 60)
        XCTAssertEqual(accumulator.peaks.count, MeetingWaveformAccumulator.maximumBins)
        XCTAssertEqual(accumulator.envelope.duration, 172_800)
        XCTAssertGreaterThan(accumulator.binDuration, 0.1)
    }

    func testDecoderAndPersistentCachePreserveActualAudioAndInvalidateChangedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("meeting.m4a")
        try await makeAAC(at: media, amplitude: 0.6)
        let original = try Data(contentsOf: media)
        let cache = MeetingWaveformCache()
        let absent = await cache.envelope(forLocalMediaURL: media)
        XCTAssertNil(absent, "Timeline reads never fall back to decoding audio")
        async let first = MeetingWaveformMetadata.prepareAndEmbed(forLocalMediaURL: media)
        async let second = MeetingWaveformMetadata.prepareAndEmbed(forLocalMediaURL: media)
        let values = try await (first, second)
        let envelope = values.0
        XCTAssertEqual(envelope, values.1)
        XCTAssertLessThan(envelope.peak(from: 0, to: 0.2), 0.04)
        XCTAssertGreaterThan(envelope.peak(from: 0.3, to: 0.7), 0.3)
        XCTAssertLessThan(envelope.peak(from: 0.8, to: 1), 0.04)
        let embedded = try Data(contentsOf: media)
        XCTAssertEqual(embedded.prefix(original.count), original, "All original compressed bytes and offsets stay unchanged")
        XCTAssertEqual(embedded.count - original.count, envelope.peaks.count + 104)
        let cached = await cache.envelope(forLocalMediaURL: media)
        XCTAssertEqual(envelope, cached)
        // The same real media reader remains able to decode the appended file.
        let decodedAfter = try await MeetingWaveformExtractor.extract(url: media)
        XCTAssertEqual(envelope, decodedAfter)
        let replacement = root.appendingPathComponent("replacement.m4a")
        try await makeAAC(at: replacement, amplitude: 0.15)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.moveItem(at: replacement, to: media)
        let metadataAbsent = await cache.envelope(forLocalMediaURL: media)
        XCTAssertNil(metadataAbsent, "Changed recording cannot reuse the previous envelope")
        _ = try await MeetingWaveformMetadata.prepareAndEmbed(forLocalMediaURL: media)
        let changed = await cache.envelope(forLocalMediaURL: media)
        XCTAssertLessThan(try XCTUnwrap(changed).peak(from: 0.3, to: 0.7), 0.3)
        XCTAssertNotEqual(envelope, changed)
    }

    func testLegacyIndexPreservesPublishedBytesAndSurvivesRehydration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("published.m4a")
        let index = root.appendingPathComponent("durable-index")
        try await makeAAC(at: media, amplitude: 0.4)
        let original = try Data(contentsOf: media)
        let before = try FileManager.default.attributesOfItem(atPath: media.path)
        let envelope = try await MeetingWaveformMetadata.prepareLegacyIndex(forLocalMediaURL: media, directory: index)
        XCTAssertEqual(try Data(contentsOf: media), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: media.path)[.modificationDate] as? Date,
            before[.modificationDate] as? Date)
        XCTAssertNil(try MeetingWaveformMetadata.read(fromLocalMediaURL: media))
        XCTAssertEqual(try MeetingWaveformMetadata.readAvailable(fromLocalMediaURL: media, directory: index), envelope)
        try FileManager.default.removeItem(at: media)
        try original.write(to: media)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: media.path)
        let cache = MeetingWaveformCache(legacyIndexDirectory: index)
        let restored = await cache.envelope(forLocalMediaURL: media)
        XCTAssertEqual(restored, envelope, "Restoration's new inode/mtime must not require audio decoding again")
        let repeated = try await MeetingWaveformMetadata.prepareLegacyIndex(forLocalMediaURL: media, directory: index)
        XCTAssertEqual(repeated, envelope)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: index, includingPropertiesForKeys: nil).count, 1)
        let replacement = root.appendingPathComponent("replacement.m4a")
        try await makeAAC(at: replacement, amplitude: 0.1)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.moveItem(at: replacement, to: media)
        XCTAssertNil(try MeetingWaveformMetadata.readAvailable(fromLocalMediaURL: media, directory: index),
            "A different recording cannot inherit another recording's legacy waveform")
    }

    func testMissingRemoteAndCorruptMediaFailWithoutCreatingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MeetingWaveformCache()
        let remote = await cache.envelope(forLocalMediaURL: URL(string: "https://example.invalid/meeting.mp4")!)
        let missing = await cache.envelope(forLocalMediaURL: root.appendingPathComponent("missing.mp4"))
        XCTAssertNil(remote)
        XCTAssertNil(missing)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("broken.mp4")
        try Data("invalid".utf8).write(to: corrupt)
        let broken = await cache.envelope(forLocalMediaURL: corrupt)
        XCTAssertNil(broken)
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("invalid".utf8))
    }

    private func makeAAC(at url: URL, amplitude: Float) async throws {
        let source = url.deletingPathExtension().appendingPathExtension("wav")
        try stereoWAV(amplitude: amplitude).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = AVURLAsset(url: source)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        try await exporter.export(to: url, as: .m4a)
    }

    /// A second of real stereo PCM: silent / opposite-phase signal / silent.
    /// No synthesized waveform enters production; this file tests the decoder.
    private func stereoWAV(amplitude: Float) -> Data {
        let sampleRate = 8_000
        var payload = Data()
        for frame in 0..<sampleRate {
            let level: Float = (2_000..<6_000).contains(frame) ? amplitude : 0
            // A 400 Hz tone survives the recording codec's low-pass filter.
            let value = Int16((level * 32_767 * Float(sin(Double(frame) * 2 * .pi * 400 / 8_000))).rounded())
            append(value, to: &payload)
            append(-value, to: &payload)
        }
        var data = Data("RIFF".utf8)
        append(UInt32(36 + payload.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(2), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 4), to: &data)
        append(UInt16(4), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
#endif
