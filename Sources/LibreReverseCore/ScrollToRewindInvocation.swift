import Foundation

public struct ScrollToRewindModifiers: Equatable, Sendable {
    public var command: Bool
    public var option: Bool
    public var shift: Bool

    public init(command: Bool = false, option: Bool = false, shift: Bool = false) {
        self.command = command
        self.option = option
        self.shift = shift
    }
}

public struct ScrollToRewindEvent: Equatable, Sendable {
    public var scrollingDeltaX: Double
    public var scrollingDeltaY: Double
    public var phaseRawValue: UInt
    public var momentumPhaseRawValue: UInt
    public var modifiers: ScrollToRewindModifiers

    public init(
        scrollingDeltaX: Double,
        scrollingDeltaY: Double,
        phaseRawValue: UInt,
        momentumPhaseRawValue: UInt,
        modifiers: ScrollToRewindModifiers
    ) {
        self.scrollingDeltaX = scrollingDeltaX
        self.scrollingDeltaY = scrollingDeltaY
        self.phaseRawValue = phaseRawValue
        self.momentumPhaseRawValue = momentumPhaseRawValue
        self.modifiers = modifiers
    }
}

public struct ScrollToRewindDecision: Equatable, Sendable {
    public let isPressingModifierKeys: Bool
    public let shouldOpen: Bool
}

/// Decides whether a modified scroll gesture should open timeline playback.
public enum ScrollToRewindInvocation {
    /// Enable scroll-wheel invocation when no saved preference exists.
    public static let defaultEnabled = true
    public static let scrollWheelEventMask: UInt64 = 0x0040_0000
    public static let openingMagnitudeThreshold = 1.0
    public static let beganPhaseRawValue: UInt = 1

    /// Requires Command + Shift with Option clear.
    /// Other modifiers do not affect invocation.
    public static func modifiersMatch(_ modifiers: ScrollToRewindModifiers) -> Bool {
        modifiers.command && modifiers.shift && !modifiers.option
    }

    public static func decision(
        previousIsPressingModifierKeys: Bool,
        event: ScrollToRewindEvent
    ) -> ScrollToRewindDecision {
        let shouldRefreshModifiers = event.phaseRawValue == beganPhaseRawValue
            || (event.phaseRawValue == 0 && event.momentumPhaseRawValue == 0)
        let pressing = shouldRefreshModifiers
            ? modifiersMatch(event.modifiers)
            : previousIsPressingModifierKeys

        // As in the timeline scroll routine, ties select Y.
        let dominantMagnitude = abs(event.scrollingDeltaY) < abs(event.scrollingDeltaX)
            ? abs(event.scrollingDeltaX)
            : abs(event.scrollingDeltaY)
        return ScrollToRewindDecision(
            isPressingModifierKeys: pressing,
            // ARM branches away only for ordered `< 1`; unordered (NaN) is
            // therefore accepted too, unlike spelling this as Swift `>=`.
            shouldOpen: pressing && !(dominantMagnitude < openingMagnitudeThreshold)
        )
    }
}
