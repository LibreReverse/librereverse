#if os(macOS)
import Darwin
import Foundation

public enum LibreReverseLibraryKeyError: Error, Equatable, LocalizedError {
    case notPrivate(URL)
    case invalidLength(URL)
    case invalidUTF8(URL)

    public var errorDescription: String? {
        switch self {
        case let .notPrivate(url): "Database key permissions are not private: \(url.path)"
        case let .invalidLength(url): "Database key has an invalid length: \(url.path)"
        case let .invalidUTF8(url): "Database key is not valid UTF-8: \(url.path)"
        }
    }
}

public enum LibreReverseLibraryKey {
    public static func createIfNeeded(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            try validate(url)
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var bytes = [UInt8](repeating: 0, count: 48)
        let descriptor = open("/dev/urandom", O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard read(descriptor, &bytes, bytes.count) == bytes.count else {
            throw CocoaError(.fileReadUnknown)
        }
        let key = Data(bytes).base64EncodedData()
        try key.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try validate(url)
    }

    public static func validate(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else {
            throw LibreReverseLibraryKeyError.notPrivate(url)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 4096 else {
            throw LibreReverseLibraryKeyError.invalidLength(url)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw LibreReverseLibraryKeyError.invalidUTF8(url)
        }
    }
}
#endif
