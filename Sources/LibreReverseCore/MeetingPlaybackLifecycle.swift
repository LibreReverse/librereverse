import Foundation

public enum LibreReverseMeetingPlaybackItemEvent: Equatable, Sendable {
    case ended
    case stalled
    case failed
}

public enum LibreReverseMeetingPlaybackItemAction: Equatable, Sendable {
    case ignore
    case advance(LibreReverseTimelineSnapshot.MeetingSelection)
    case stopAtMeetingEnd
    case pauseForRetry
    case stopAndInvalidate
}

public enum LibreReverseMeetingPlaybackFailureSurface: Equatable, Sendable {
    case persistedStill
    case errorOnly
}

public enum LibreReverseMeetingPlaybackNoticeKind: Equatable, Sendable {
    case stalled
    case failedToPrepare
    case failedDuringPlayback
    case retrying

    public var offersMediaReload: Bool {
        switch self {
        case .failedToPrepare, .failedDuringPlayback: true
        case .stalled, .retrying: false
        }
    }
}

public struct LibreReverseMeetingPlaybackNotice: Equatable, Sendable {
    public let segmentID: Int64
    public let kind: LibreReverseMeetingPlaybackNoticeKind

    public init(segmentID: Int64, kind: LibreReverseMeetingPlaybackNoticeKind) {
        self.segmentID = segmentID
        self.kind = kind
    }
}

/// Segment-scoped follower status. A same-segment transcript refresh retains
/// playback feedback, while a child/meeting switch clears it. This prevents an
/// async transcript publication from hiding a media failure for the view the
/// user is still looking at.
public struct LibreReverseMeetingPlaybackNoticeState: Equatable, Sendable {
    public private(set) var notice: LibreReverseMeetingPlaybackNotice?

    public init(notice: LibreReverseMeetingPlaybackNotice? = nil) {
        self.notice = notice
    }

    @discardableResult
    public mutating func present(
        _ kind: LibreReverseMeetingPlaybackNoticeKind,
        for segmentID: Int64,
        selectedSegmentID: Int64?
    ) -> Bool {
        guard selectedSegmentID == segmentID else { return false }
        notice = .init(segmentID: segmentID, kind: kind)
        return true
    }

    public mutating func transcriptDidPresent(segmentID: Int64) {
        if notice?.segmentID != segmentID { notice = nil }
    }

    @discardableResult
    public mutating func retryDidBegin(segmentID: Int64) -> Bool {
        guard notice?.segmentID == segmentID,
            notice?.kind.offersMediaReload == true
        else { return false }
        notice = .init(segmentID: segmentID, kind: .retrying)
        return true
    }

    public mutating func mediaDidBecomeReady(segmentID: Int64) {
        if notice?.segmentID == segmentID { notice = nil }
    }

    public mutating func clear() {
        notice = nil
    }
}

/// Keeps AVFoundation callbacks subordinate to the currently presented item.
/// Cached AVPlayers replace items and can deliver a late notification from the
/// item they used to own, so both item identity and presentation generation
/// must match before a callback is allowed to mutate playback state.
public enum LibreReverseMeetingPlaybackItemPolicy {
    public static func action(
        for event: LibreReverseMeetingPlaybackItemEvent,
        playbackIsActive: Bool,
        ownsPresentedItem: Bool,
        followingSelection: LibreReverseTimelineSnapshot.MeetingSelection?
    ) -> LibreReverseMeetingPlaybackItemAction {
        guard playbackIsActive, ownsPresentedItem else { return .ignore }
        switch event {
        case .ended:
            return followingSelection.map(LibreReverseMeetingPlaybackItemAction.advance)
                ?? .stopAtMeetingEnd
        case .stalled:
            return .pauseForRetry
        case .failed:
            return .stopAndInvalidate
        }
    }

    /// The wall clock is only allowed to move while AVPlayer is moving. This
    /// prevents transcript/timeline progress during buffering or failed media.
    public static func shouldAdvanceWallClock(playerIsPlaying: Bool) -> Bool {
        playerIsPlaying
    }

    public static func failureSurface(
        hasPersistedStill: Bool
    ) -> LibreReverseMeetingPlaybackFailureSurface {
        hasPersistedStill ? .persistedStill : .errorOnly
    }
}

/// Historical playback advances on the same compressed axis as scrubbing.
/// Gaps have no playable media and therefore consume no playback time.
public enum LibreReverseTimelinePlaybackNavigation {
    public static func advance(from date: Date, elapsed: TimeInterval,
        snapshot: LibreReverseTimelineSnapshot) -> Date? {
        guard let offset = snapshot.contiguousOffset(atWallDate: date) else { return nil }
        let target = offset + max(0, elapsed)
        // Continue requesting beyond a bounded window so its replacement can
        // load following history; only the global library end stops playback.
        if target > snapshot.contiguousDuration,
            let end = snapshot.validSeekInterval?.end {
            return max(date, end).addingTimeInterval(max(0, elapsed))
        }
        return snapshot.wallDate(atContiguousOffset: target)
    }
}

/// Sparse history has one presentation beat per saved change, regardless of
/// how long the desktop was unchanged. Meetings use their own media clock.
public struct LibreReverseHistoryPlaybackStep: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let startUptimeNanoseconds: UInt64
    public let duration: TimeInterval

    public init(start: Date, end: Date, startUptimeNanoseconds: UInt64,
        duration: TimeInterval = 0.25) {
        self.start = start
        self.end = max(start, end)
        self.startUptimeNanoseconds = startUptimeNanoseconds
        self.duration = max(0.001, duration)
    }

    public static func nextDate(after date: Date, frameDate: Date?, meetingStart: Date?) -> Date? {
        [frameDate, meetingStart].compactMap { $0 }.filter { $0 > date }.min()
    }

    public func fraction(at uptime: UInt64) -> Double {
        guard uptime >= startUptimeNanoseconds else { return 0 }
        return min(1, Double(uptime - startUptimeNanoseconds) / 1_000_000_000 / duration)
    }

    public func wallDate(at uptime: UInt64) -> Date {
        start.addingTimeInterval(end.timeIntervalSince(start) * fraction(at: uptime))
    }

    public func isComplete(at uptime: UInt64) -> Bool { fraction(at: uptime) >= 1 }
}
