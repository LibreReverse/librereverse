import Foundation

/// One presentation second per elapsed second, independent of media type.
/// Wall-clock dates are obtained from the shared, nonlinear display axis.
public enum TimelineBeltPlayback {
    public struct Position {
        public let date: Date
        public let meetingID: Int64?
        public let reachedWindowEdge: Bool
    }
    public static func position(from start: Date, elapsed: TimeInterval,
                                snapshot: LibreReverseTimelineSnapshot) -> Position? {
        guard let offset = snapshot.contiguousOffset(atWallDate: start) else { return nil }
        let target = min(snapshot.contiguousDuration, offset + max(0, elapsed))
        guard let date = snapshot.wallDate(atContiguousOffset: target) else { return nil }
        if let meeting = snapshot.rawAudioSegments.filter({ $0.startDate >= start && $0.startDate <= date })
            .min(by: { $0.startDate < $1.startDate }) {
            return Position(date: meeting.startDate, meetingID: meeting.rawID, reachedWindowEdge: false)
        }
        return Position(date: date, meetingID: nil, reachedWindowEdge: target >= snapshot.contiguousDuration)
    }
    public static func frame(at date: Date, dates: [Date]) -> Date? {
        var low = 0, high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] <= date { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? dates[low - 1] : nil
    }
}
