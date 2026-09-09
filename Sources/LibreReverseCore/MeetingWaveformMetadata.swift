#if os(macOS)
import CryptoKit
import Foundation

public enum MeetingWaveformMetadataError: Error, LocalizedError {
    case invalidContainer, terminalUnboundedAtom, changedDuringPreparation, invalidEnvelope
    public var errorDescription: String? {
        switch self {
        case .invalidContainer: return "The recording has an unsupported or damaged MP4 atom layout."
        case .terminalUnboundedAtom: return "The recording ends in an unbounded atom and cannot accept metadata safely."
        case .changedDuringPreparation: return "The recording changed while waveform metadata was prepared."
        case .invalidEnvelope: return "The recording's waveform metadata is invalid."
        }
    }
}

/// An ISO BMFF user-extension (`uuid`) atom. Unknown boxes are skipped by media
/// readers; append preserves all existing media offsets and compressed bytes.
/// See https://mp4ra.org/registered-types/boxes and Apple's QuickTime Atoms spec.
public enum MeetingWaveformMetadata {
    // 6DB79157-1BBA-4E08-A345-D78B6E692104, private LibreReverse waveform format.
    private static let identifier = Data([0x6d, 0xb7, 0x91, 0x57, 0x1b, 0xba, 0x4e, 0x08,
        0xa3, 0x45, 0xd7, 0x8b, 0x6e, 0x69, 0x21, 0x04])
    private static let magic = Data("LRWAVE01".utf8)
    private static let footerMagic = Data("LRWVEND1".utf8)
    private static let maximumAtomSize = 131_200

    /// Metadata only: usually two bounded reads at EOF, with a header-only scan
    /// fallback if another tool subsequently appended a different atom.
    public static func read(fromLocalMediaURL url: URL) throws -> MeetingWaveformEnvelope? {
        guard url.isFileURL else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        if length >= 16 {
            try file.seek(toOffset: length - 16)
            let footer = try readExactly(file, count: 16)
            if footer.prefix(8) == footerMagic {
                let count = integer(footer, at: 8, bytes: 8)
                if count >= 104, count <= maximumAtomSize, count <= length {
                    try file.seek(toOffset: length - count)
                    if let result = decode(try readExactly(file, count: Int(count))) { return result }
                }
            }
        }
        var latest: MeetingWaveformEnvelope?
        try scan(file, length: length) { offset, size, headerSize, type in
            guard type == "uuid", size >= UInt64(headerSize + 16), size <= maximumAtomSize else { return }
            try file.seek(toOffset: offset)
            if let envelope = decode(try readExactly(file, count: Int(size))) { latest = envelope }
        }
        return latest
    }

    /// Explicit preparation ONLY. Call on a finalized private staging recording
    /// before integrity hashes and publication, never from drawing or playback.
    /// Existing published files require a migration that stages and commits new
    /// media plus their integrity records together. No video/audio is reencoded.
    public static func prepareAndEmbed(forLocalMediaURL url: URL) async throws -> MeetingWaveformEnvelope {
        try await MeetingWaveformPreparation.shared.prepare(url)
    }

    /// Legacy canonical media are immutable once published and checksummed.
    /// Their durable index is populated explicitly by backfill; timeline reads
    /// never trigger decoding. Embedded metadata always takes precedence.
    public static func readAvailable(fromLocalMediaURL url: URL, directory: URL? = nil) throws -> MeetingWaveformEnvelope? {
        if let embedded = try? read(fromLocalMediaURL: url) { return embedded }
        return try readLegacyIndex(url, directory: directory ?? legacyIndexDirectory)
    }

    public static func prepareLegacyIndex(forLocalMediaURL url: URL, directory: URL? = nil) async throws -> MeetingWaveformEnvelope {
        try await MeetingWaveformPreparation.shared.prepare(url, legacyDirectory: directory ?? legacyIndexDirectory)
    }

    private static var legacyIndexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LibreReverse/MeetingWaveforms-v1", isDirectory: true)
    }

    private static func readLegacyIndex(_ url: URL, directory: URL) throws -> MeetingWaveformEnvelope? {
        guard let key = try legacyIdentity(url) else { return nil }
        let file = directory.appendingPathComponent(key).appendingPathExtension("lrwf")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= maximumAtomSize else { return nil }
        return decode(try Data(contentsOf: file))
    }

    static func prepareLegacyUnserialized(_ url: URL, directory: URL) async throws -> MeetingWaveformEnvelope {
        try Task.checkCancellation()
        if let existing = try readAvailable(fromLocalMediaURL: url, directory: directory) { return existing }
        guard let key = try legacyIdentity(url) else { throw MeetingWaveformMetadataError.invalidContainer }
        let envelope = try await MeetingWaveformExtractor.extract(url: url)
        try Task.checkCancellation()
        guard try legacyIdentity(url) == key else { throw MeetingWaveformMetadataError.changedDuringPreparation }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(key).appendingPathExtension("lrwf")
        try encode(envelope).write(to: file, options: .atomic)
        return envelope
    }

    /// Stable across rehydration (new inode/mtime) while detecting changed header
    /// or tail bytes. This is an identity hint for immutable canonical paths,
    /// not a replacement for the archive's authoritative whole-file checksum.
    private static func legacyIdentity(_ url: URL) throws -> String? {
        guard url.isFileURL else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length > 0 else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(url.standardizedFileURL.path.utf8))
        var byteCount = Data()
        append(length, to: &byteCount)
        hasher.update(data: byteCount)
        try file.seek(toOffset: 0)
        hasher.update(data: try readExactly(file, count: Int(min(length, 65_536))))
        if length > 65_536 {
            try file.seek(toOffset: length - 65_536)
            hasher.update(data: try readExactly(file, count: 65_536))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func prepareUnserialized(_ url: URL) async throws -> MeetingWaveformEnvelope {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MeetingWaveformMetadataError.invalidContainer }
        if let existing = try read(fromLocalMediaURL: url) { return existing }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalSize = (before[.size] as? NSNumber)?.uint64Value
        let originalModified = before[.modificationDate] as? Date
        let value = try await MeetingWaveformExtractor.extract(url: url)
        try Task.checkCancellation()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard originalSize == (after[.size] as? NSNumber)?.uint64Value,
              originalModified == after[.modificationDate] as? Date,
              (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) else {
            throw MeetingWaveformMetadataError.changedDuringPreparation
        }
        try embed(value, in: url)
        return value
    }

    /// Internal for byte-layout tests. The caller owns a private staging file.
    static func embed(_ value: MeetingWaveformEnvelope, in url: URL) throws {
        guard url.isFileURL else { throw MeetingWaveformMetadataError.invalidContainer }
        let atom = try encode(value)
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let originalLength = try file.seekToEnd()
        var hasFileType = false
        try scan(file, length: originalLength, forAppend: true) { _, _, _, type in
            if type == "ftyp" { hasFileType = true }
        }
        guard hasFileType else { throw MeetingWaveformMetadataError.invalidContainer }
        guard try file.seekToEnd() == originalLength else {
            throw MeetingWaveformMetadataError.changedDuringPreparation
        }
        try file.seek(toOffset: originalLength)
        do {
            try file.write(contentsOf: atom)
            try file.synchronize()
        } catch {
            // Restore original bytes after ordinary write errors. Process-crash
            // atomicity is supplied by the caller's staging/publication boundary.
            try? file.truncate(atOffset: originalLength)
            try? file.synchronize()
            throw error
        }
    }

    private static func encode(_ value: MeetingWaveformEnvelope) throws -> Data {
        guard value.duration.isFinite, value.duration > 0,
            value.binDuration.isFinite, value.binDuration >= 0.1,
            value.peaks.count <= MeetingWaveformAccumulator.maximumBins else {
            throw MeetingWaveformMetadataError.invalidEnvelope
        }
        var payload = magic
        append(UInt16(1), to: &payload) // schema version
        append(UInt16(value.peaks.isEmpty ? 1 : 0), to: &payload) // no audio track
        append(UInt32(value.peaks.count), to: &payload)
        append(value.duration.bitPattern, to: &payload)
        append(value.binDuration.bitPattern, to: &payload)
        payload.append(value.peaks)
        let digest = Data(SHA256.hash(data: payload))
        let size = 24 + payload.count + digest.count + 16
        var atom = Data()
        append(UInt32(size), to: &atom)
        atom.append(Data("uuid".utf8))
        atom.append(identifier)
        atom.append(payload)
        atom.append(digest)
        atom.append(footerMagic)
        append(UInt64(size), to: &atom)
        return atom
    }

    private static func decode(_ atom: Data) -> MeetingWaveformEnvelope? {
        guard atom.count >= 104, atom.count <= maximumAtomSize,
            integer(atom, at: 0, bytes: 4) == atom.count,
            atom[4..<8] == Data("uuid".utf8), atom[8..<24] == identifier,
            atom[24..<32] == magic, integer(atom, at: 32, bytes: 2) == 1,
            integer(atom, at: 34, bytes: 2) <= 1 else { return nil }
        let count = Int(integer(atom, at: 36, bytes: 4))
        guard count <= MeetingWaveformAccumulator.maximumBins, atom.count == 104 + count,
            atom[(atom.count - 16)..<(atom.count - 8)] == footerMagic,
            integer(atom, at: atom.count - 8, bytes: 8) == atom.count else { return nil }
        let duration = Double(bitPattern: integer(atom, at: 40, bytes: 8))
        let binDuration = Double(bitPattern: integer(atom, at: 48, bytes: 8))
        guard duration.isFinite, duration > 0, binDuration.isFinite, binDuration >= 0.1,
            (count == 0) == (integer(atom, at: 34, bytes: 2) == 1),
            Data(SHA256.hash(data: atom[24..<(56 + count)])) == atom[(56 + count)..<(88 + count)] else { return nil }
        return .init(duration: duration, binDuration: binDuration, peaks: Data(atom[56..<(56 + count)]))
    }

    /// Seek across mdat rather than reading it. Handle >4 GB extended sizes,
    /// terminal size-zero boxes, invalid sizes and excessive header counts.
    private static func scan(_ file: FileHandle, length: UInt64, forAppend: Bool = false,
        visit: (UInt64, UInt64, Int, String) throws -> Void) throws {
        var offset: UInt64 = 0
        var count = 0
        while offset < length {
            count += 1
            guard count <= 4_096, length - offset >= 8 else { throw MeetingWaveformMetadataError.invalidContainer }
            try file.seek(toOffset: offset)
            let header = try readExactly(file, count: 8)
            let size32 = integer(header, at: 0, bytes: 4)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var size = size32
            var headerSize = 8
            if size32 == 1 {
                guard length - offset >= 16 else { throw MeetingWaveformMetadataError.invalidContainer }
                size = integer(try readExactly(file, count: 8), at: 0, bytes: 8)
                headerSize = 16
            } else if size32 == 0 {
                if forAppend { throw MeetingWaveformMetadataError.terminalUnboundedAtom }
                size = length - offset
            }
            guard size >= headerSize, size <= length - offset else { throw MeetingWaveformMetadataError.invalidContainer }
            try visit(offset, size, headerSize, type)
            offset += size
        }
    }

    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else {
            throw MeetingWaveformMetadataError.invalidContainer
        }
        return data
    }
    private static func integer(_ bytes: Data, at start: Int, bytes count: Int) -> UInt64 {
        bytes[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func append<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var bigEndian = number.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Explicit preparations share one utility worker; opening the timeline never
/// reaches this actor. Deduplicate finalize/backfill requests for one pathname.
private actor MeetingWaveformPreparation {
    static let shared = MeetingWaveformPreparation()
    private struct Key: Hashable { let url: URL; let directory: URL? }
    private var pending: [Key: Task<MeetingWaveformEnvelope, Error>] = [:]
    private var tail: Task<MeetingWaveformEnvelope, Error>?

    func prepare(_ url: URL, legacyDirectory: URL? = nil) async throws -> MeetingWaveformEnvelope {
        try Task.checkCancellation()
        let key = Key(url: url, directory: legacyDirectory)
        if let task = pending[key] { return try await task.value }
        let predecessor = tail
        let task = Task.detached(priority: .utility) {
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            if let legacyDirectory {
                return try await MeetingWaveformMetadata.prepareLegacyUnserialized(url, directory: legacyDirectory)
            }
            return try await MeetingWaveformMetadata.prepareUnserialized(url)
        }
        pending[key] = task
        tail = task
        defer {
            pending[key] = nil
            if pending.isEmpty { tail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
#endif
