import Foundation

/// Search index for ordered presentation intervals. Two binary searches bound
/// visible items without scanning the entire timeline on every movement.
public struct TimelinePresentationIndex: Sendable {
    public struct Interval: Equatable, Sendable {
        public let offset: TimeInterval
        public let duration: TimeInterval

        public init(offset: TimeInterval, duration: TimeInterval) {
            self.offset = offset
            self.duration = max(0, duration)
        }

        public var endOffset: TimeInterval { offset + duration }
    }

    public let intervals: [Interval]
    private let prefixMaximumEnds: [TimeInterval]

    public init(intervals: [Interval]) {
        self.intervals = intervals
        var maximumEnd = -TimeInterval.greatestFiniteMagnitude
        self.prefixMaximumEnds = intervals.map { interval in
            maximumEnd = max(maximumEnd, interval.endOffset)
            return maximumEnd
        }
    }

    /// Returns indices whose half-open intervals intersect the requested
    /// half-open visible range. Prefix maxima make the first search correct for
    /// nested/overlapping intervals without falling back to a linear scan.
    public func visibleRange(
        centeredAt centerOffset: TimeInterval,
        duration: TimeInterval
    ) -> Range<Int> {
        guard !intervals.isEmpty, duration > 0 else { return 0..<0 }
        let halfDuration = duration * 0.5
        let lower = centerOffset - halfDuration
        let upper = centerOffset + halfDuration

        var low = 0
        var high = prefixMaximumEnds.count
        while low < high {
            let middle = (low + high) / 2
            if prefixMaximumEnds[middle] > lower {
                high = middle
            } else {
                low = middle + 1
            }
        }
        let first = low

        low = first
        high = intervals.count
        while low < high {
            let middle = (low + high) / 2
            if intervals[middle].offset < upper {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return first..<low
    }
}
