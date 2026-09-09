#if os(macOS)
import Foundation

public enum VideoStorage {
    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter
    }()

    public static func relativePath(xid: String, date: Date) -> String {
        yearMonthFormatter.string(from: date)
            + "/" + dayFormatter.string(from: date)
            + "/" + xid
    }

    /// The video directory layout is `yyyyMM/dd/<xid>`.
    /// Keeping this check beside the path producer prevents a second local
    /// video namespace from silently reappearing in another recorder or tool.
    public static func isCanonicalRelativePath(_ path: String, xid: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[2] == Substring(xid),
              !xid.isEmpty,
              components[0].count == 6,
              components[1].count == 2,
              components[0].allSatisfy(\.isNumber),
              components[1].allSatisfy(\.isNumber),
              let month = Int(components[0].suffix(2)),
              let day = Int(components[1]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return false }
        return true
    }

    public static func temporaryVideoURL(
        chunksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: chunksDirectory,
            create: true
        )
        return replacementDirectory.appendingPathComponent("video.mp4")
    }

    public static func storeTemporaryVideo(
        at temporaryURL: URL,
        relativePath: String,
        chunksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = chunksDirectory.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: temporaryURL, to: destination)
        // The app cleanup is explicitly nonfatal after a successful move.
        try? removeEmptyParentDirectories(
            of: temporaryURL,
            fileManager: fileManager
        )
        return destination
    }

    private static func removeEmptyParentDirectories(
        of sourceURL: URL,
        fileManager: FileManager
    ) throws {
        var directory = sourceURL.deletingLastPathComponent()
        while !directory.pathComponents.isEmpty {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsSubdirectoryDescendants
            ) else { return }
            guard enumerator.nextObject() == nil else { return }
            try fileManager.removeItem(at: directory)
            directory.deleteLastPathComponent()
        }
    }
}
#endif
