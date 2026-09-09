import Foundation

/// Rational scrub seek tolerance derived from the media frame rate.
public enum PlaybackTiming {
    public struct TimeComponents: Equatable, Sendable {
        public let value: Int64
        public let timescale: Int32

        public init(value: Int64, timescale: Int32) {
            self.value = value
            self.timescale = timescale
        }
    }

    /// Returns one quarter-frame as an integer CMTime pair. Integral rates
    /// use multiplier 1, half-integral rates use 2, and other rates use 1000.
    public static func seekTolerance(frameRate: Double) -> TimeComponents? {
        guard frameRate.isFinite, frameRate > 0 else { return nil }
        let multiplier: Int64
        if frameRate.rounded(.towardZero) == frameRate {
            multiplier = 1
        } else if (frameRate * 2).rounded(.towardZero) == frameRate * 2 {
            multiplier = 2
        } else {
            multiplier = 1_000
        }
        let rawTimescale = (Double(multiplier) * frameRate * 4).rounded(.towardZero)
        guard rawTimescale >= 1, rawTimescale <= Double(Int32.max) else { return nil }
        return TimeComponents(value: multiplier, timescale: Int32(rawTimescale))
    }
}

/// Wall-clock reconstruction for a persisted meeting anchor. A
/// meeting owns one durable frame at media time zero; later transcript seeks
/// must use elapsed segment time rather than repeatedly returning to that
/// anchor frame index.
public enum LibreReverseMeetingPlaybackTiming {
    public static func mediaTime(
        requestedDate: Date,
        segmentStartDate: Date?,
        segmentType: SegmentType?,
        anchorFrameIndex: Int,
        frameRate: Double
    ) -> TimeInterval? {
        if segmentType == .audio, let segmentStartDate {
            return max(0, requestedDate.timeIntervalSince(segmentStartDate))
        }
        guard frameRate.isFinite, frameRate > 0 else { return nil }
        return max(0, Double(anchorFrameIndex) / frameRate)
    }
}

/// A monotonic playback clock keeps UI/transcript wall time tied to elapsed
/// real time instead of accumulating an assumed timer interval. Dispatch
/// timers can be delayed by rendering, database, or archive work; adding a
/// fixed interval per callback would make AVPlayer audio run ahead forever.
public struct LibreReverseWallClockPlaybackClock: Equatable, Sendable {
    public let startWallDate: Date
    public let startUptimeNanoseconds: UInt64

    public init(startWallDate: Date, startUptimeNanoseconds: UInt64) {
        self.startWallDate = startWallDate
        self.startUptimeNanoseconds = startUptimeNanoseconds
    }

    public func wallDate(at uptimeNanoseconds: UInt64) -> Date {
        guard uptimeNanoseconds > startUptimeNanoseconds else { return startWallDate }
        return startWallDate.addingTimeInterval(
            Double(uptimeNanoseconds - startUptimeNanoseconds) / 1_000_000_000
        )
    }
}

public enum LibreReverseMeetingPlaybackControlPolicy {
    /// Remote/unprepared media cannot start playback, but an active transition
    /// must always remain pausable even while its replacement is not ready.
    public static func isEnabled(
        hasAction: Bool,
        isActive: Bool,
        mediaAvailable: Bool
    ) -> Bool {
        hasAction && (isActive || mediaAvailable)
    }

    public enum ToggleDecision: Equatable, Sendable {
        case start
        case stop
        case ignore
    }

    /// Applies the same readiness rule to non-button entry points such as the
    /// Space shortcut. Stopping is always allowed, but starting requires both
    /// a ready current player and media belonging to the selected moment.
    public static func toggleDecision(
        hasPresentedPlayer: Bool,
        isActive: Bool,
        mediaAvailable: Bool
    ) -> ToggleDecision {
        if isActive { return .stop }
        return hasPresentedPlayer && mediaAvailable ? .start : .ignore
    }
}

/// Readiness is scoped to one selected/presented media transaction. A retained
/// AVPlayer is not proof that its file still belongs to the current database
/// generation, especially while deletion or shard replacement is underway.
public struct LibreReverseMeetingPlaybackReadiness: Equatable, Sendable {
    public private(set) var mediaAvailable: Bool

    public init(mediaAvailable: Bool = false) {
        self.mediaAvailable = mediaAvailable
    }

    public mutating func mediaDidBecomeReady() {
        mediaAvailable = true
    }

    public mutating func invalidate() {
        mediaAvailable = false
    }

    public func toggleDecision(
        hasPresentedPlayer: Bool,
        isActive: Bool
    ) -> LibreReverseMeetingPlaybackControlPolicy.ToggleDecision {
        LibreReverseMeetingPlaybackControlPolicy.toggleDecision(
            hasPresentedPlayer: hasPresentedPlayer,
            isActive: isActive,
            mediaAvailable: mediaAvailable
        )
    }
}

public enum LibreReverseMeetingReloadSelectionPolicy {
    /// A bounded historical reload may retain its selected meeting. Reloading
    /// at the live edge, or without a seek position to resolve, must not carry
    /// a stale meeting identity into the new timeline generation.
    public static func retainedSegmentID(
        startAtLiveEdge: Bool,
        preservedSeekDate: Date?,
        preservedSegmentID: Int64?
    ) -> Int64? {
        guard !startAtLiveEdge, preservedSeekDate != nil else { return nil }
        return preservedSegmentID
    }
}

public enum LibreReverseTimelineReloadRequest: Equatable, Sendable {
    case recent(duration: TimeInterval)
    case around(date: Date, duration: TimeInterval)

    public static func make(
        startAtLiveEdge: Bool,
        preservedSeekDate: Date?,
        lastFetchedDuration: TimeInterval,
        defaultDuration: TimeInterval
    ) -> Self {
        let duration =
            lastFetchedDuration.isFinite && lastFetchedDuration > 0
            ? lastFetchedDuration : defaultDuration
        if !startAtLiveEdge, let preservedSeekDate {
            return .around(date: preservedSeekDate, duration: duration)
        }
        return .recent(duration: duration)
    }
}
