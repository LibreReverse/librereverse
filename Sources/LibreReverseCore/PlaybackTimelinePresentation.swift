import Foundation

/// Playback-only geometry. Never supplies bounds, offsets or durations to the
/// navigation pager: those remain owned by the unweighted library snapshot.
public struct PlaybackTimelinePresentation {
    public let snapshot: LibreReverseTimelineSnapshot
    public let interval: DateInterval
    public let frameDates: [Date]
    private let sourceWindow: HistoricalTimelineSegmentWindow

    public init?(window: HistoricalTimelineSegmentWindow, starredDates: [Date] = []) {
        guard let dates = window.playbackFrameDates, !dates.isEmpty,
            let start = window.segments.map(\.startDate).min(),
            let end = window.segments.map(\.endDate).max(), end > start else { return nil }
        sourceWindow = window
        frameDates = dates.sorted()
        interval = DateInterval(start: start, end: end)
        snapshot = .init(rawSegments: window.segments,
            validSeekInterval: window.validSeekInterval, starredDates: starredDates, playbackFrameDates: dates)
    }

    public var includesLiveTail: Bool {
        sourceWindow.validSeekInterval.map { interval.end >= $0.end } ?? false
    }

    public func withStarredDates(_ dates: [Date]) -> Self {
        Self(window: sourceWindow, starredDates: dates) ?? self
    }

    /// Missing archive timing is a loading state, not permission to change units.
    public func refreshed(window: HistoricalTimelineSegmentWindow, starredDates: [Date]) -> Self {
        Self(window: window, starredDates: starredDates)
            ?? Self(window: .init(segments: sourceWindow.segments,
                validSeekInterval: window.validSeekInterval ?? sourceWindow.validSeekInterval,
                playbackFrameDates: frameDates), starredDates: starredDates)
            ?? self
    }

    public func appending(admittedFrame: LibreReverseAdmittedFrame, starredDates: [Date] = [],
                          retaining date: Date? = nil, maximumDuration: TimeInterval = 7200) -> Self {
        guard let segment = admittedFrame.segment else { return self }
        let end = max(interval.end, segment.endDate)
        let valid = DateInterval(start: sourceWindow.validSeekInterval?.start ?? interval.start,
            end: max(sourceWindow.validSeekInterval?.end ?? end, end))
        let cutoff = end.addingTimeInterval(-max(1, maximumDuration))
        if let date, date < cutoff {
            // Keep a stationary historical selection intact. This window is no
            // longer the live tail; ordinary paging can extend it when needed.
            return Self(window: .init(segments: sourceWindow.segments,
                validSeekInterval: valid, playbackFrameDates: frameDates),
                starredDates: starredDates) ?? self
        }
        var segments = sourceWindow.segments
        if let index = segments.firstIndex(where: { $0.rawID == segment.rawID && $0.rawType == segment.rawType }) {
            segments[index] = segment
        } else { segments.append(segment) }
        var dates = Array(Set(frameDates + [admittedFrame.createdAt])).sorted()
        // Start at the preceding real frame so trimming cannot change the
        // quarter-second spacing of the first retained interval.
        if let start = dates.last(where: { $0 <= cutoff }) {
            dates.removeAll { $0 < start }
            segments = segments.compactMap { original in
                guard original.endDate > start else { return nil }
                // Audio starts are media-clock origins, so retain them intact.
                guard original.rawType == .capturedScreen, original.startDate < start else { return original }
                return TimelineSegment(startDate: start, endDate: original.endDate,
                    bundleID: original.bundleID, windowName: original.windowName,
                    browserURL: original.browserURL, browserProfile: original.browserProfile,
                    mergedSegmentIDs: original.mergedSegmentIDs, rawID: original.rawID,
                    rawType: original.rawType)
            }
        }
        return Self(window: .init(segments: segments,
            validSeekInterval: valid, playbackFrameDates: dates),
            starredDates: starredDates) ?? self
    }

    /// Load ahead of the visible edges, using the same compressed units as drawing.
    public func needsMoreHistory(around date: Date, padding: TimeInterval) -> Bool {
        guard let valid = sourceWindow.validSeekInterval,
              let offset = snapshot.contiguousOffset(atWallDate: date) else { return false }
        return (interval.start > valid.start && offset < padding)
            || (interval.end < valid.end && snapshot.contiguousDuration - offset < padding)
    }

    public func contains(_ date: Date) -> Bool {
        interval.start <= date && date <= interval.end
    }
}

public enum LibreReverseTimelinePresentationPolicy {
    public static func pointsPerSecond(zoomLevel: Float) -> Double {
        24 * pow(2, Double(zoomLevel - TimelineLayout.defaultZoomLevel) / 10)
    }

    public static func appGroups(_ segments: [TimelineSegment]) -> [AppSegmentGroup] {
        var groups: [[TimelineSegment]] = []
        for segment in segments where segment.rawType == .capturedScreen {
            if let last = groups.last?.last,
                let bundle = last.bundleID, bundle == segment.bundleID,
                segment.startDate.timeIntervalSince(last.endDate) <= TimelineSegmentProcessor.appGroupMaximumGap {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        // A capture remains the displayed moment until the next capture. Fill
        // the short inter-app handoff in drawing space too; otherwise that held
        // frame becomes an expanding blank as the user zooms in. Dates and the
        // playback axis remain untouched, as do genuinely missing intervals.
        for index in groups.indices.dropLast() {
            guard let last = groups[index].last, let next = groups[index + 1].first,
                next.startDate.timeIntervalSince(last.endDate) <= TimelineSegmentProcessor.appGroupMaximumGap,
                let end = last.contiguousEndOffset, let nextStart = next.contiguousStartOffset,
                nextStart > end, nextStart - end <= 0.250001 else { continue }
            groups[index][groups[index].count - 1].contiguousEndOffset = nextStart
        }
        return groups.enumerated().map { .init(index: $0.offset, segments: $0.element) }
    }
}
