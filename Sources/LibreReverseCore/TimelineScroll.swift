import Foundation

public enum TimelineScrubbingSource: UInt8, Sendable {
    case globalScroll = 0
    case localScroll = 1
    case timelinePan = 2
    case click = 3
}

public enum TimelineScrollType: UInt8, Sendable {
    case normal = 0
    case manuallyFast = 1
    case shiftPowerUp = 2
}

public struct TimelineScrollModifiers: Equatable, Sendable {
    public var command: Bool
    public var option: Bool
    public var shift: Bool

    public init(command: Bool = false, option: Bool = false, shift: Bool = false) {
        self.command = command
        self.option = option
        self.shift = shift
    }
}

public struct TimelineScrollResult: Equatable, Sendable {
    public let delta: Double
    public let scrollType: TimelineScrollType
}

/// Converts dominant-axis input to timeline movement with source-specific gain.
public enum TimelineScroll {
    /// Dominant input magnitude above which scrolling is classified as fast.
    public static let manuallyFastThreshold = 325.0
    public static let shiftPowerUpMultiplier = 40.0
    public static let preciseDeltaDivisor = 10.0
    public static let localZoomDivisor = 5.0
    /// Minimum input magnitude after gesture admission. Smaller momentum samples
    /// stop driving the timeline.
    public static let minimumDominantDelta = 1.0

    public static func timeDelta(
        scrollingDeltaX: Double,
        scrollingDeltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        modifiers: TimelineScrollModifiers,
        zoomLevel: Double,
        source: TimelineScrubbingSource
    ) -> TimelineScrollResult {
        // Choose Y on equal magnitudes or unordered comparisons; otherwise use the
        // stronger axis. Timeline movement has the opposite sign from input.
        let dominant = abs(scrollingDeltaY) < abs(scrollingDeltaX)
            ? scrollingDeltaX
            : scrollingDeltaY
        var delta = -dominant

        let scrollType: TimelineScrollType
        if !modifiers.command && !modifiers.option && modifiers.shift {
            delta *= shiftPowerUpMultiplier
            scrollType = .shiftPowerUp
        } else {
            scrollType = abs(delta) > manuallyFastThreshold ? .manuallyFast : .normal
        }

        if hasPreciseScrollingDeltas {
            delta /= preciseDeltaDivisor
        }

        // Global scroll and timeline pan apply zoom gain. Local scroll and click
        // keep their input scale; multiplying local wheel input here exaggerates
        // movement at the default zoom.
        if source.rawValue & 1 == 0 {
            delta *= zoomLevel / localZoomDivisor
        }

        return TimelineScrollResult(delta: delta, scrollType: scrollType)
    }
}
