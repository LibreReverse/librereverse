import Foundation

/// A seek emitted by timeline UI together with the reducer provenance that
/// controls its update timing.
public struct TimelineSeekRequest: Sendable {
    public let date: Date
    public let source: SeekPositionUpdateSource
    public let contiguousOffset: TimeInterval?

    public init(
        date: Date,
        source: SeekPositionUpdateSource,
        contiguousOffset: TimeInterval? = nil
    ) {
        self.date = date
        self.source = source
        self.contiguousOffset = contiguousOffset
    }

}

public enum TimelineEndOwnership {
    /// The unweighted navigation path maps a bounded right clamp to the global
    /// valid end, independently of the local final segment date.
    public static func pinTarget(
        localOffset: TimeInterval,
        localDuration: TimeInterval,
        globalValidEnd: Date?,
        advancesForward: Bool
    ) -> Date? {
        guard advancesForward, localOffset >= localDuration else { return nil }
        return globalValidEnd
    }
}

/// Keeps the live edge pinned for the remainder of a physical scroll gesture.
public struct LibreReverseTimelineLiveGestureLatch: Equatable, Sendable {
    public private(set) var reachedEnd = false

    public init() {}

    /// Returns whether this event belongs to the already-completed gesture and
    /// should therefore be ignored. A new phased gesture and every phaseless
    /// mouse-wheel event start with an unlocked edge.
    public mutating func prepareForEvent(
        beginsGesture: Bool,
        isPhaseless: Bool
    ) -> Bool {
        if beginsGesture || isPhaseless {
            reachedEnd = false
        }
        return reachedEnd && !isPhaseless
    }

    public mutating func didReachEnd(isPhaseless: Bool) {
        if !isPhaseless {
            reachedEnd = true
        }
    }

    /// The latch protects only the touch/contact portion of one gesture.
    /// Momentum has its own live-pin guard, so retaining this bit after the
    /// phased gesture ends can only poison a later gesture when AppKit omits a
    /// fresh `.began` sample.
    public mutating func gestureEnded() {
        reachedEnd = false
    }
}
