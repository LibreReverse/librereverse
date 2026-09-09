import Foundation

public enum SegmentType: Int, Codable, Sendable {
    case capturedScreen = 0
    case audio = 1
    case importedScreenshot = 2
    case websiteVisit = 3
}

public enum SeekPositionUpdateSource: Int, CaseIterable, Sendable {
    case askRewind = 0
    case search = 1
    case jumpToDate = 2
    case keyboardShortcut = 3
    case jumpToEnd = 4
    case drag = 5
    case click = 6
    case scroll = 7
    case summarization = 8
    case pinToEnd = 9
    case audioPlayer = 10
    case isInitialLoad = 11
}

public enum SegmentLegacyType: CaseIterable, Sendable {
    case audio
    case screenshot
}

public enum TimelineInteractionTiming {
    /// Minimum interval between admitted bounds-driven seeks.
    public static let boundsInterval: TimeInterval = 0.1

    /// Minimum interval between admitted seeks for each scroll mode.
    public static func scrollInterval(for type: TimelineScrollType) -> TimeInterval {
        switch type {
        case .normal:
            return 0.1
        case .manuallyFast, .shiftPowerUp:
            return 0.2
        }
    }
}

/// Leading-edge throttle for seek work. Each instance tracks its last admitted
/// update; suppressed events are dropped rather than deferred. Callers must
/// resolve final gesture positions explicitly when they require a settled frame.
public struct TimelineSeekThrottle: Sendable {
    /// Timestamp of the last admitted update.
    public private(set) var lastUpdate: Date

    public init(lastUpdate: Date = .distantPast) {
        self.lastUpdate = lastUpdate
    }

    /// Returns whether an update is admitted at `now` for `interval`.
    ///
    /// The update proceeds only when elapsed time is strictly greater than interval.
    public mutating func admits(
        interval: TimeInterval,
        now: Date
    ) -> Bool {
        let elapsed = now.timeIntervalSince(lastUpdate)
        guard interval < elapsed else { return false }
        lastUpdate = now
        return true
    }
}

public struct TimelineSegment: Codable, Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let bundleID: String?
    public var contiguousStartOffset: TimeInterval?
    public var contiguousEndOffset: TimeInterval?
    public let windowName: String?
    public let browserURL: String?
    public let browserProfile: String?
    public var mergedSegmentIDs: [Int64]?
    public let rawID: Int64
    public let rawType: SegmentType

    public init(
        startDate: Date,
        endDate: Date,
        bundleID: String?,
        contiguousStartOffset: TimeInterval? = nil,
        contiguousEndOffset: TimeInterval? = nil,
        windowName: String? = nil,
        browserURL: String? = nil,
        browserProfile: String? = nil,
        mergedSegmentIDs: [Int64]? = nil,
        rawID: Int64,
        rawType: SegmentType
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.bundleID = bundleID
        self.contiguousStartOffset = contiguousStartOffset
        self.contiguousEndOffset = contiguousEndOffset
        self.windowName = windowName
        self.browserURL = browserURL
        self.browserProfile = browserProfile
        self.mergedSegmentIDs = mergedSegmentIDs
        self.rawID = rawID
        self.rawType = rawType
    }

    public var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }
}

/// A recording publication that arrived after a database fetch began. Its
/// revision lets the completed fetch replay newer changes without losing them.
public struct RecordingSegmentPublication: Equatable, Sendable {
    public let revision: UInt64
    public let segment: TimelineSegment

    public init(revision: UInt64, segment: TimelineSegment) {
        self.revision = revision
        self.segment = segment
    }
}

public enum RecordingWindowReconciliation {
    public struct Result: Equatable, Sendable {
        public let segments: [TimelineSegment]
        public let validSeekInterval: DateInterval?
    }

    /// Completes a bounded replacement at its original actor position, then
    /// replays recording messages which arrived while its DB snapshot was in
    /// flight. With no later recording message this remains an exact complete
    /// replacement, not a union with the previously retained window.
    public static func reconcile(
        fetchedSegments: [TimelineSegment],
        fetchedValidSeekInterval: DateInterval?,
        recordingPublications: [RecordingSegmentPublication],
        after revision: UInt64
    ) -> Result {
        let later = recordingPublications.filter { $0.revision > revision }
        guard !later.isEmpty else {
            return Result(
                segments: fetchedSegments,
                validSeekInterval: fetchedValidSeekInterval
            )
        }

        var segments = fetchedSegments
        var interval = fetchedValidSeekInterval
        for publication in later {
            let segment = publication.segment
            if let index = segments.lastIndex(where: {
                $0.rawID == segment.rawID && $0.rawType == segment.rawType
            }) {
                segments[index] = segment
            } else {
                segments.append(segment)
            }
            if let current = interval {
                interval = DateInterval(
                    start: min(current.start, segment.startDate),
                    end: max(current.end, segment.endDate)
                )
            } else {
                interval = DateInterval(start: segment.startDate, end: segment.endDate)
            }
        }
        return Result(segments: segments, validSeekInterval: interval)
    }
}

/// A starred frame projected onto the contiguous timeline axis.
public struct StarredFrameItem: Equatable, Sendable {
    public let date: Date
    public let contiguousOffset: TimeInterval

    public init(date: Date, contiguousOffset: TimeInterval) {
        self.date = date
        self.contiguousOffset = contiguousOffset
    }
}

public struct AppSegmentGroup: Equatable, Sendable {
    public let index: Int
    public let segments: [TimelineSegment]
    public let dateInterval: DateInterval

    public init(index: Int, segments: [TimelineSegment]) {
        precondition(!segments.isEmpty)
        self.index = index
        self.segments = segments
        self.dateInterval = DateInterval(
            start: segments[0].startDate,
            end: segments[segments.count - 1].endDate
        )
    }
}

public enum TimelineSegmentProcessor {
    /// Maximum inter-segment gap considered for application grouping.
    public static let appGroupMaximumGap: TimeInterval = 240

    public static func websiteHost(for rawURL: String?) -> String? {
        guard let rawURL, !rawURL.isEmpty else { return nil }
        let candidate = rawURL.contains("://") ? rawURL : "http://" + rawURL
        return URL(string: candidate)?.host
    }

    public static func belongsInSameAppGroup(
        previous: TimelineSegment,
        next: TimelineSegment
    ) -> Bool {
        guard previous.bundleID == next.bundleID else { return false }
        guard websiteHost(for: previous.browserURL) == websiteHost(for: next.browserURL) else {
            return false
        }
        return next.startDate < previous.endDate.addingTimeInterval(appGroupMaximumGap)
    }

    public static func groupCapturedScreenSegments(
        _ segments: [TimelineSegment]
    ) -> [AppSegmentGroup] {
        var result: [AppSegmentGroup] = []
        var current: [TimelineSegment] = []
        for segment in segments where segment.rawType == .capturedScreen {
            if let previous = current.last,
               !belongsInSameAppGroup(previous: previous, next: segment) {
                result.append(AppSegmentGroup(index: result.count, segments: current))
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty {
            result.append(AppSegmentGroup(index: result.count, segments: current))
        }
        return result
    }
}
