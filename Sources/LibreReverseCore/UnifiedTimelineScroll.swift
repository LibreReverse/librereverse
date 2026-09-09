import Foundation

/// Visual distances never double as database window durations.
public enum UnifiedTimelineScroll {
    public struct Step {
        public let date: Date
        public let remainder: Double
    }
    public static func step(snapshot: LibreReverseTimelineSnapshot, from date: Date,
                            distance: Double) -> Step? {
        guard let start = snapshot.contiguousOffset(atWallDate: date) else { return nil }
        let target = min(snapshot.contiguousDuration, max(0, start + distance))
        guard let date = snapshot.wallDate(atContiguousOffset: target) else { return nil }
        return Step(date: date, remainder: distance - (target - start))
    }
    public static func distance(pixels: Double, zoom: Float) -> Double {
        pixels / LibreReverseTimelinePresentationPolicy.pointsPerSecond(zoomLevel: zoom)
    }
}
