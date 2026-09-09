#if os(macOS)
import Darwin
import Foundation

/// Explicit diagnostics contain event categories and elapsed times only. They
/// never persist the free-form message's query, title, path, URL, or error text.
enum LibreReverseTimelineTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["LIBREREVERSE_TIMELINE_TRACE"] == "1"
    static let isBoundaryEnabled = ProcessInfo.processInfo.environment["LIBREREVERSE_BOUNDARY_TRACE"] == "1"
    private static let origin = DispatchTime.now().uptimeNanoseconds
    private static let handle = makeLog(enabled: isEnabled, name: "timeline.log")
    private static let boundaryHandle = makeLog(enabled: isBoundaryEnabled, name: "boundary.log")

    private static func makeLog(enabled: Bool, name: String) -> LibreReverseBoundedDiagnosticLog? {
        guard enabled,
            let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_DIAGNOSTICS_DIRECTORY"],
            directory.hasPrefix("/")
        else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return LibreReverseBoundedDiagnosticLog(url: root.appendingPathComponent(name))
        } catch { return nil }
    }

    static func eventCategory(_ message: String) -> String {
        let first = String(message.prefix(80).prefix { $0.isLetter }).uppercased()
        let allowed: Set<String> = [
            "SURFACE", "RENDER", "SEEK", "RESOLVE", "PREPARE", "PRESENT",
            "WINDOW", "FETCH", "PLAYBACK", "PINLATCH", "PIN", "SCROLL",
            "LIVETEXT", "SEARCHPAGE", "SEARCHSTAGE", "SEARCH", "LAYOUT",
            "STEP", "BOUNDARY", "GESTURE", "PUBLISH", "SCROLLTOCURRENTDATE",
        ]
        return allowed.contains(first) ? first : "EVENT"
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        write(message(), to: handle)
    }

    static func boundary(_ message: @autoclosure () -> String) {
        guard isBoundaryEnabled, let boundaryHandle else { return }
        write(message(), to: boundaryHandle)
    }

    private static func write(_ message: String, to log: LibreReverseBoundedDiagnosticLog) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- origin) / 1_000_000
        log.append(String(format: "%10.1fms %@\n", milliseconds, eventCategory(message)))
    }
}

/// Each explicitly selected log is capped and replaced at launch. O_NOFOLLOW
/// prevents a pre-existing symlink from redirecting diagnostic writes.
final class LibreReverseBoundedDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int
    private var writtenBytes = 0

    init?(url: URL, maximumBytes: Int = 1_048_576) {
        guard maximumBytes > 0 else { return nil }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        // An existing file may have broader permissions than the create mode.
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.maximumBytes = maximumBytes
    }

    func append(_ line: String) {
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard data.count <= maximumBytes - writtenBytes else { return }
        do {
            try handle.write(contentsOf: data)
            writtenBytes += data.count
        } catch {
            writtenBytes = maximumBytes
        }
    }
}
#endif
