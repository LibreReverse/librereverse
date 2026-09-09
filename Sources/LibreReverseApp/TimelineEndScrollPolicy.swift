import Foundation

/// An invisible, fixed-size navigation lane after Now, never part of the
/// timeline's date/zoom geometry. Momentum cannot push through the exit.
struct TimelineEndScrollPolicy {
    static let exitDistance = 80.0
    private(set) var offset = 0.0

    mutating func advance(atLiveEdge: Bool, pixels: Double, momentum: Bool) -> (history: Double, exit: Bool) {
        guard atLiveEdge else { offset = 0; return (pixels, false) }
        if momentum { return (0, false) }
        let target = offset + pixels
        offset = min(Self.exitDistance, max(0, target))
        return (min(0, target), target >= Self.exitDistance)
    }
}
