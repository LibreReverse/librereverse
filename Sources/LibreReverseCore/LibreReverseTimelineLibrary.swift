#if os(macOS)
import Foundation

public struct LibreReverseTimelineSnapshot: Sendable {
    public struct MeetingSelection: Equatable, Sendable {
        public let segmentID: Int64
        public let seekDate: Date

        public init(segmentID: Int64, seekDate: Date) {
            self.segmentID = segmentID
            self.seekDate = seekDate
        }
    }

    private let axisSegments: [TimelineSegment]
    public let processedSegments: [TimelineSegment]
    public let processedAudioSegments: [TimelineSegment]
    public let processedScreenshotSegments: [TimelineSegment]
    public let rawAudioSegments: [TimelineSegment]
    public let appGroups: [AppSegmentGroup]
    public let validSeekInterval: DateInterval?
    public let contiguousDuration: TimeInterval
    public let starredFrames: [StarredFrameItem]

    public init(
        rawSegments: [TimelineSegment],
        validSeekInterval globalValidSeekInterval: DateInterval? = nil,
        starredDates: [Date] = [],
        playbackFrameDates: [Date]? = nil
    ) {
        let rawAudioSegments = rawSegments.filter { $0.rawType == .audio }
        let reconstruction = TimelineOffsetReconstruction.reconstructFull(
            audioSegments: rawAudioSegments,
            screenshotSegments: rawSegments.filter { $0.rawType == .capturedScreen }
        )
        // One shared axis must cover the UNION of both media tracks. Counting
        // screenshot gaps inside a spanning meeting a second time makes the
        // forward and inverse mappings disagree and reverses forward scrolling.
        var intervals: [DateInterval] = []
        for segment in reconstruction.processedSegments {
            guard segment.endDate > segment.startDate else { continue }
            if let last = intervals.last, segment.startDate <= last.end {
                intervals[intervals.count - 1] = DateInterval(start: last.start,
                    end: max(last.end, segment.endDate))
            } else {
                intervals.append(DateInterval(start: segment.startDate, end: segment.endDate))
            }
        }
        var offset: TimeInterval = 0
        let axis: [TimelineSegment]
        if let playbackFrameDates, let start = intervals.first?.start, let end = intervals.last?.end {
            // Every ordinary saved change occupies a quarter playback second.
            // Meeting intervals retain one timeline second per media second.
            let anchors = Array(Set(playbackFrameDates + rawAudioSegments.flatMap { [$0.startDate, $0.endDate] })).sorted()
            let boundaries = Array(Set([start, end] + anchors.filter { start < $0 && $0 < end }
                + intervals.flatMap { [$0.start, $0.end] })).sorted()
            var result: [TimelineSegment] = []
            var anchorIndex = -1
            for (left, right) in zip(boundaries, boundaries.dropFirst()) where right > left {
                while anchorIndex + 1 < anchors.count && anchors[anchorIndex + 1] <= left { anchorIndex += 1 }
                let meeting = rawAudioSegments.contains { $0.startDate <= left && left < $0.endDate }
                let duration: TimeInterval
                if meeting { duration = right.timeIntervalSince(left) }
                else {
                    let previous = anchors.indices.contains(anchorIndex) && anchors[anchorIndex] <= left ? anchors[anchorIndex] : start
                    let following = anchors.indices.contains(anchorIndex + 1) ? anchors[anchorIndex + 1] : end
                    duration = 0.25 * right.timeIntervalSince(left) / max(0.001, following.timeIntervalSince(previous))
                }
                result.append(.init(startDate: left, endDate: right, bundleID: nil,
                    contiguousStartOffset: offset, contiguousEndOffset: offset + duration,
                    rawID: Int64(result.count), rawType: meeting ? .audio : .capturedScreen))
                offset += duration
            }
            axis = result
        } else {
            axis = intervals.enumerated().map { index, interval in
                defer { offset += interval.duration }
                return TimelineSegment(startDate: interval.start, endDate: interval.end,
                    bundleID: nil, contiguousStartOffset: offset,
                    contiguousEndOffset: offset + interval.duration, rawID: Int64(index), rawType: .capturedScreen)
            }
        }
        self.axisSegments = axis
        let processed = reconstruction.processedSegments.map { original in
            var segment = original
            segment.contiguousStartOffset = Self.contiguousOffset(atWallDate: original.startDate, in: axis)
            segment.contiguousEndOffset = Self.contiguousOffset(atWallDate: original.endDate, in: axis)
            return segment
        }
        let screenshots = processed.filter { $0.rawType == .capturedScreen }
        self.processedSegments = processed
        self.processedAudioSegments = processed.filter { $0.rawType == .audio }
        self.processedScreenshotSegments = screenshots
        self.rawAudioSegments = rawAudioSegments
        self.appGroups = TimelineSegmentProcessor.groupCapturedScreenSegments(screenshots)
        self.validSeekInterval =
            globalValidSeekInterval
            ?? axis.first.flatMap { first in
                axis.last.map { DateInterval(start: first.startDate, end: $0.endDate) }
            }
        self.contiguousDuration = offset
        self.starredFrames = Self.mapStarredDates(
            starredDates,
            in: axis,
            validSeekInterval: self.validSeekInterval
        )
    }

    /// The timeline visually coalesces nearby audio rows while retaining
    /// only the first row’s raw ID. Resolve merged children by wall time for
    /// media and transcript selection. Visual gaps clamp to the nearest real
    /// boundary, with a tie preferring the following segment.
    public func meetingSelection(
        at requestedDate: Date,
        anchoredBy segmentID: Int64,
        clampOuterBounds: Bool = true
    ) -> MeetingSelection? {
        guard
            let merged = processedAudioSegments.first(where: {
                $0.rawID == segmentID || ($0.mergedSegmentIDs ?? []).contains(segmentID)
            })
        else { return nil }
        let memberIDs = Set([merged.rawID] + (merged.mergedSegmentIDs ?? []))
        let children = rawAudioSegments.filter { memberIDs.contains($0.rawID) }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.rawID < $1.rawID
        }
        guard let first = children.first, let last = children.last else { return nil }
        if !clampOuterBounds,
            requestedDate < first.startDate || requestedDate >= last.endDate
        {
            return nil
        }
        if requestedDate <= first.startDate {
            return .init(segmentID: first.rawID, seekDate: first.startDate)
        }
        if requestedDate >= last.endDate {
            return .init(segmentID: last.rawID, seekDate: last.endDate)
        }
        if let containing = children.last(where: {
            $0.startDate <= requestedDate && requestedDate < $0.endDate
        }) {
            return .init(segmentID: containing.rawID, seekDate: requestedDate)
        }
        let previous = children.last(where: { $0.endDate <= requestedDate })
        let following = children.first(where: { requestedDate < $0.startDate })
        switch (previous, following) {
        case (let previous?, let following?):
            let previousDistance = requestedDate.timeIntervalSince(previous.endDate)
            let followingDistance = following.startDate.timeIntervalSince(requestedDate)
            return previousDistance < followingDistance
                ? .init(segmentID: previous.rawID, seekDate: previous.endDate)
                : .init(segmentID: following.rawID, seekDate: following.startDate)
        case (let previous?, nil):
            return .init(segmentID: previous.rawID, seekDate: previous.endDate)
        case (nil, let following?):
            return .init(segmentID: following.rawID, seekDate: following.startDate)
        case (nil, nil):
            return nil
        }
    }

    /// Returns the next physical audio child in the same visually merged
    /// meeting. Playback needs this explicit relationship when AVPlayer reaches
    /// the end of a file before the wall-clock timer crosses a small merge gap.
    public func followingMeetingSelection(
        after childSegmentID: Int64,
        anchoredBy segmentID: Int64
    ) -> MeetingSelection? {
        guard
            let merged = processedAudioSegments.first(where: {
                $0.rawID == segmentID || ($0.mergedSegmentIDs ?? []).contains(segmentID)
            })
        else { return nil }
        let memberIDs = Set([merged.rawID] + (merged.mergedSegmentIDs ?? []))
        let children = rawAudioSegments.filter { memberIDs.contains($0.rawID) }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.rawID < $1.rawID
        }
        guard
            let currentIndex = children.firstIndex(where: { $0.rawID == childSegmentID }),
            children.indices.contains(currentIndex + 1)
        else { return nil }
        let following = children[currentIndex + 1]
        return .init(segmentID: following.rawID, seekDate: following.startDate)
    }

    private static func mapStarredDates(
        _ dates: [Date],
        in screenshots: [TimelineSegment],
        validSeekInterval: DateInterval?
    ) -> [StarredFrameItem] {
        guard let validSeekInterval else { return [] }
        return dates.compactMap { date in
            guard validSeekInterval.contains(date),
                let contiguousOffset = contiguousOffset(
                    atWallDate: date,
                    in: screenshots
                )
            else { return nil }
            return StarredFrameItem(
                date: date,
                contiguousOffset: contiguousOffset
            )
        }
    }

    private static func contiguousOffset(
        atWallDate date: Date,
        in axis: [TimelineSegment]
    ) -> TimeInterval? {
        guard let first = axis.first, let last = axis.last else { return nil }
        if date <= first.startDate { return 0 }
        if date >= last.endDate { return last.contiguousEndOffset }
        var lower = 0
        var upper = axis.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if axis[middle].startDate <= date { lower = middle + 1 }
            else { upper = middle }
        }
        let segment = axis[max(0, lower - 1)]
        let duration = segment.endDate.timeIntervalSince(segment.startDate)
        let fraction = min(1, max(0, date.timeIntervalSince(segment.startDate) / max(0.001, duration)))
        let start = segment.contiguousStartOffset ?? 0
        return start + fraction * ((segment.contiguousEndOffset ?? start) - start)
    }

    /// Converts the gap-compressed timeline coordinate back to a wall date.
    /// Interior boundaries select the following segment; the final boundary
    /// selects the last segment's end.
    public func wallDate(atContiguousOffset requestedOffset: TimeInterval) -> Date? {
        guard !axisSegments.isEmpty,
            let last = axisSegments.last
        else { return nil }
        let offset = min(max(0, requestedOffset), contiguousDuration)
        if offset == contiguousDuration { return last.endDate }
        // Waveform drawing projects visible audio bins through this inverse
        // mapping. Find the first end strictly after the offset without scanning
        // every retained screen frame for each visible bar.
        var lower = 0, upper = axisSegments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if offset < (axisSegments[middle].contiguousEndOffset ?? 0) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        guard lower < axisSegments.count else { return last.endDate }
        let segment = axisSegments[lower]
        let startOffset = segment.contiguousStartOffset ?? 0
        let axisDuration = (segment.contiguousEndOffset ?? startOffset) - startOffset
        return segment.startDate.addingTimeInterval(
            (offset - startOffset) / max(0.000001, axisDuration) * segment.endDate.timeIntervalSince(segment.startDate))
    }

    /// Converts a wall date to the gap-compressed timeline coordinate.
    ///
    /// `processedScreenshotSegments` is sorted by `startDate`, so this binary
    /// searches rather than scanning. The previous linear scan ran on every
    /// scrub event — twice per seek — and its cost grew with the whole loaded
    /// corpus. Semantics are unchanged and are pinned by
    /// `LibreReverseTimelineSnapshotOffsetTests`, which cross-checks this against
    /// the original linear definition.
    public func contiguousOffset(atWallDate date: Date) -> TimeInterval? {
        Self.contiguousOffset(atWallDate: date, in: axisSegments)
    }

}

public enum LibreReverseTimelineLibrary {
    public static func loadSnapshot(
        configuration: LibraryDatabaseConfiguration
    ) throws -> LibreReverseTimelineSnapshot {
        let window = try LibraryDatabase.loadRecentTimelineWindow(
            configuration: configuration
        )
        return LibreReverseTimelineSnapshot(
            rawSegments: window.segments,
            validSeekInterval: window.validSeekInterval
        )
    }

    public static func nearestMoment(
        to date: Date,
        configuration: LibraryDatabaseConfiguration
    ) throws -> HistoricalTimelineMoment? {
        try LibraryDatabase.nearestMoment(to: date, configuration: configuration)
    }
}
#endif
