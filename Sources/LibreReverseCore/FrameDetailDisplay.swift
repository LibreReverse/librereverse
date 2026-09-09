import Foundation

/// Screen-frame visibility uses a strict three-second distance from now.
/// Its cutoff is independent of the five-second publication facet policy.
public enum FrameDetailVisibility {
    public static let liveCutoffSeconds: TimeInterval = 3.0

    public static func isHidden(
        segmentType: SegmentType?,
        currentSeekPosition: Date?,
        now: Date
    ) -> Bool {
        guard segmentType == .capturedScreen else { return true }
        guard let currentSeekPosition else { return false }
        return abs(currentSeekPosition.distance(to: now)) < liveCutoffSeconds
    }
}

/// A selected meeting keeps the shared media surface visible even without a
/// screenshot segment. Hiding it also pauses AVPlayer, so screen-only visibility
/// must not interrupt meeting playback.
public enum LibreReverseTimelineSurfaceVisibility {
    public static func isHidden(
        frameDetailHidden: Bool,
        hasSelectedMeetingMedia: Bool
    ) -> Bool {
        frameDetailHidden && !hasSelectedMeetingMedia
    }
}

/// One media surface combines a display mode with a hidden flag. Loading
/// retains existing content; hiding reveals the live desktop.
public enum FrameDetailDisplayMode: Int, CaseIterable, Equatable, Sendable {
    case image = 0
    case loading = 1
    case video = 2
}

/// The resolved presentation for one moment.
public struct FrameDetailPresentation: Equatable, Sendable {
    /// When true nothing is drawn and the transparent window shows the desktop.
    public let isHidden: Bool
    public let displayMode: FrameDetailDisplayMode

    public init(isHidden: Bool, displayMode: FrameDetailDisplayMode) {
        self.isHidden = isHidden
        self.displayMode = displayMode
    }
}

/// Retains the most recent image across unresolved/loading updates. A newly
/// resolved image replaces it; this is a single retained surface, not a cache.
public final class FrameDetailImageRetention<Image: AnyObject> {
    public private(set) var lastImage: Image?

    public init() {}

    /// Replaces the single retained image. Nil represents loading and holds
    /// the existing image rather than blanking it.
    @discardableResult
    public func update(with image: Image?) -> Bool {
        guard let image else { return false }
        guard lastImage !== image else { return false }
        lastImage = image
        return true
    }

    /// Explicitly releases the retained image.
    public func clear() {
        lastImage = nil
    }
}

public enum FrameDetailDisplay {
    /// Hidden state takes precedence. Otherwise choose video, then image, then
    /// loading while retaining the outgoing surface.
    public static func presentation(
        isHidden: Bool,
        hasVideo: Bool,
        hasImage: Bool
    ) -> FrameDetailPresentation {
        if isHidden {
            return FrameDetailPresentation(isHidden: true, displayMode: .loading)
        }
        if hasVideo {
            return FrameDetailPresentation(isHidden: false, displayMode: .video)
        }
        if hasImage {
            return FrameDetailPresentation(isHidden: false, displayMode: .image)
        }
        // Unresolved: hold in `loading` instead of blanking. Retaining the
        // outgoing surface is what prevents the swap flicker.
        return FrameDetailPresentation(isHidden: false, displayMode: .loading)
    }
}
