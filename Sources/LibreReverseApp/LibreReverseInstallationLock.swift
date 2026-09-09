#if os(macOS)
import Darwin
import Foundation

/// Holds exclusive ownership of the app's library until shutdown finishes.
final class LibreReverseInstallationLock {
    enum Error: Swift.Error, LocalizedError {
        case unsafeDirectory
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory:
                "The library directory must be a real directory, not a symbolic link."
            case .unavailable:
                "Another app instance owns this library, or its lock cannot be opened. Quit the other instance before opening LibreReverse."
            }
        }
    }

    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Error.unsafeDirectory }
        let url = directory.appendingPathComponent("librereverse.lock")
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw Error.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Error.unavailable
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
#endif
