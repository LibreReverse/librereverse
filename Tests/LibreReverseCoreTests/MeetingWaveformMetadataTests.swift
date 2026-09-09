#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingWaveformMetadataTests: XCTestCase {
    func testRoundTripAndForeignTrailingAtomUseMetadataOnly() throws {
        try withFile { url in
            let envelope = MeetingWaveformEnvelope(duration: 1, binDuration: 0.1,
                peaks: Data([0, 12, 64, 255, 0, 0, 2, 1, 0, 0]))
            try container().write(to: url)
            try MeetingWaveformMetadata.embed(envelope, in: url)
            XCTAssertEqual(try MeetingWaveformMetadata.read(fromLocalMediaURL: url), envelope)
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            try file.write(contentsOf: box("free", payload: Data(repeating: 0, count: 16)))
            try file.close()
            XCTAssertEqual(try MeetingWaveformMetadata.read(fromLocalMediaURL: url), envelope,
                "Header-only fallback finds metadata when another atom follows")
        }
    }

    func testChecksumRejectsCorruptPeaksAndNoAudioIsExplicit() throws {
        try withFile { url in
            try container().write(to: url)
            let envelope = MeetingWaveformEnvelope(duration: 1, binDuration: 0.1, peaks: Data())
            try MeetingWaveformMetadata.embed(envelope, in: url)
            XCTAssertEqual(try MeetingWaveformMetadata.read(fromLocalMediaURL: url), envelope)
            var corrupted = try Data(contentsOf: url)
            corrupted[corrupted.count - 17] ^= 1 // digest, preceding footer
            try corrupted.write(to: url)
            XCTAssertNil(try MeetingWaveformMetadata.read(fromLocalMediaURL: url))
        }
    }

    func testSizeZeroAndMalformedContainersAreNotModified() throws {
        try withFile { url in
            var input = box("ftyp", payload: Data("isom0000".utf8))
            input.append(Data([0, 0, 0, 0]))
            input.append(Data("mdat".utf8))
            input.append(Data(repeating: 0, count: 16))
            try input.write(to: url)
            XCTAssertThrowsError(try MeetingWaveformMetadata.embed(.init(duration: 1, binDuration: 0.1, peaks: Data()), in: url))
            XCTAssertEqual(try Data(contentsOf: url), input)
            try Data([0, 0, 0, 255, 109, 100, 97, 116]).write(to: url)
            XCTAssertThrowsError(try MeetingWaveformMetadata.read(fromLocalMediaURL: url))
        }
    }

    func testExtendedSizeMediaLargerThanFiveGBIsSkippedWithoutAllocation() throws {
        try withFile { url in
            let header = box("ftyp", payload: Data("isom0000".utf8))
            try header.write(to: url)
            let file = try FileHandle(forUpdating: url)
            let mediaSize: UInt64 = 5 * 1_024 * 1_024 * 1_024 + 16
            try file.seekToEnd()
            var mediaHeader = Data([0, 0, 0, 1])
            mediaHeader.append(Data("mdat".utf8))
            var bigSize = mediaSize.bigEndian
            withUnsafeBytes(of: &bigSize) { mediaHeader.append(contentsOf: $0) }
            try file.write(contentsOf: mediaHeader)
            try file.truncate(atOffset: UInt64(header.count) + mediaSize) // sparse fixture
            try file.close()
            let envelope = MeetingWaveformEnvelope(duration: 10, binDuration: 0.1, peaks: Data(repeating: 7, count: 100))
            try MeetingWaveformMetadata.embed(envelope, in: url)
            XCTAssertEqual(try MeetingWaveformMetadata.read(fromLocalMediaURL: url), envelope)
        }
    }

    private func container() -> Data {
        box("ftyp", payload: Data("isom0000".utf8)) + box("mdat", payload: Data(repeating: 0, count: 16))
    }
    private func box(_ type: String, payload: Data) -> Data {
        var result = Data()
        var size = UInt32(payload.count + 8).bigEndian
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(Data(type.utf8))
        result.append(payload)
        return result
    }
    private func withFile(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
#endif
