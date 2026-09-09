import Foundation

/// Reconstructs shared audio/screenshot offsets.
public enum TimelineOffsetReconstruction {
    public struct FullResult: Equatable, Sendable {
        public let processedSegments: [TimelineSegment]
        public let audioSegments: [TimelineSegment]
        public let screenshotSegments: [TimelineSegment]
    }

    /// Coalesces audio, combines it with screenshots, then stably sorts by start
    /// date. Rows that cannot follow the accepted prefix are skipped.
    public static func reconstructFull(
        audioSegments rawAudioSegments: [TimelineSegment],
        screenshotSegments rawScreenshotSegments: [TimelineSegment]
    ) -> FullResult {
        let mergedAudio = mergeAudioSegments(rawAudioSegments)
        let initial = mergedAudio + rawScreenshotSegments
        // Use the original ordinal to make equal-date precedence explicit.
        let combined = initial.enumerated().sorted { lhs, rhs in
            if lhs.element.startDate != rhs.element.startDate {
                return lhs.element.startDate < rhs.element.startDate
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var processed: [TimelineSegment] = []
        var audio: [TimelineSegment] = []
        var screenshots: [TimelineSegment] = []
        processed.reserveCapacity(combined.count)
        audio.reserveCapacity(mergedAudio.count)
        screenshots.reserveCapacity(rawScreenshotSegments.count)

        for input in combined {
            var segment = input
            let computedStartOffset: TimeInterval
            if let anchor = processed.last {
                guard let anchorStart = anchor.contiguousStartOffset,
                      let anchorEnd = anchor.contiguousEndOffset,
                      let candidate = startOffset(
                          for: segment,
                          after: anchor,
                          anchorStartOffset: anchorStart,
                          anchorEndOffset: anchorEnd
                      )
                else { continue }
                computedStartOffset = candidate
            } else {
                computedStartOffset = 0
            }
            segment.contiguousStartOffset = computedStartOffset
            segment.contiguousEndOffset = computedStartOffset + nonnegativeDuration(of: segment)
            processed.append(segment)
            switch legacyType(of: segment) {
            case .audio: audio.append(segment)
            case .screenshot: screenshots.append(segment)
            }
        }
        return FullResult(
            processedSegments: processed,
            audioSegments: audio,
            screenshotSegments: screenshots
        )
    }

    /// Consecutive audio rows with matching optional bundle ID and browser host
    /// merge when the new start is strictly before the previous end plus 240 seconds.
    /// Keep the first identity and metadata, adopt the new end, and append its ID.
    public static func mergeAudioSegments(
        _ segments: [TimelineSegment]
    ) -> [TimelineSegment] {
        var result: [TimelineSegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            guard let previous = result.last,
                  previous.bundleID == segment.bundleID,
                  TimelineSegmentProcessor.websiteHost(for: previous.browserURL)
                    == TimelineSegmentProcessor.websiteHost(for: segment.browserURL),
                  segment.startDate < previous.endDate.addingTimeInterval(
                      TimelineSegmentProcessor.appGroupMaximumGap
                  )
            else {
                result.append(segment)
                continue
            }
            result.removeLast()
            var mergedIDs = previous.mergedSegmentIDs ?? []
            mergedIDs.append(segment.rawID)
            result.append(TimelineSegment(
                startDate: previous.startDate,
                endDate: segment.endDate,
                bundleID: previous.bundleID,
                contiguousStartOffset: previous.contiguousStartOffset,
                contiguousEndOffset: previous.contiguousEndOffset,
                windowName: previous.windowName,
                browserURL: previous.browserURL,
                browserProfile: previous.browserProfile,
                mergedSegmentIDs: mergedIDs,
                rawID: previous.rawID,
                rawType: previous.rawType
            ))
        }
        return result
    }

    private static func startOffset(
        for segment: TimelineSegment,
        after anchor: TimelineSegment,
        anchorStartOffset: TimeInterval,
        anchorEndOffset: TimeInterval
    ) -> TimeInterval? {
        let anchorInterval = DateInterval(
            start: anchor.startDate,
            end: max(anchor.startDate, anchor.endDate)
        )
        if anchorInterval.contains(segment.startDate) {
            return anchorStartOffset + segment.startDate.timeIntervalSince(anchor.startDate)
        }
        return segment.startDate > anchor.endDate ? anchorEndOffset : nil
    }

    private static func nonnegativeDuration(
        of segment: TimelineSegment
    ) -> TimeInterval {
        DateInterval(
            start: segment.startDate,
            end: max(segment.startDate, segment.endDate)
        ).duration
    }

    private static func legacyType(
        of segment: TimelineSegment
    ) -> SegmentLegacyType {
        switch segment.rawType {
        case .audio:
            return .audio
        case .capturedScreen:
            return .screenshot
        case .importedScreenshot, .websiteVisit:
            preconditionFailure("Not representable in SegmentLegacyType: \(segment.rawType)")
        }
    }
}
