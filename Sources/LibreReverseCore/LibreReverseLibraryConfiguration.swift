import Foundation

public struct LibreReverseLibraryConfiguration: Sendable {
    public let databaseURL: URL
    public let keyFileURL: URL
    public let mediaRoot: URL

    public init(databaseURL: URL, keyFileURL: URL, mediaRoot: URL) {
        self.databaseURL = databaseURL
        self.keyFileURL = keyFileURL
        self.mediaRoot = mediaRoot
    }
}

public extension LibreReverseLibraryConfiguration {
    /// Canonical TrackItem still-image directory for LibreReverse's storage
    /// root. Video paths remain relative to `mediaRoot` independently.
    var frameImagesRoot: URL {
        mediaRoot
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
    }
}
