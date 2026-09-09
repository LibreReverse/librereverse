import Foundation

/// Exact SegmentList-side selection used before the explorer assembles a
/// `TrackItem`. Frame lookup is intentionally separate and global.
public enum TrackItemSelection {
    /// Returns the first typed raw segment whose normalized interval contains
    /// `date`, assigning a shared endpoint to the following segment.
    ///
    /// Lower-bound on `max(startDate, endDate)`, then validate the candidate.
    /// Only inspect the following element when the requested date exactly
    /// matches the candidate's normalized end.
    public static func segment(
        at date: Date,
        type: SegmentType,
        in rawSegments: [TimelineSegment]
    ) -> TimelineSegment? {
        let typed = rawSegments.filter { $0.rawType == type }
        var lower = 0
        var upper = typed.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let normalizedEnd = max(typed[middle].startDate, typed[middle].endDate)
            if date > normalizedEnd {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < typed.count else { return nil }

        let candidate = typed[lower]
        let candidateEnd = max(candidate.startDate, candidate.endDate)
        guard candidate.startDate <= date, date <= candidateEnd else { return nil }
        guard date == candidateEnd, lower + 1 < typed.count else { return candidate }

        let following = typed[lower + 1]
        let followingEnd = max(following.startDate, following.endDate)
        return following.startDate <= date && date <= followingEnd ? following : candidate
    }
}
