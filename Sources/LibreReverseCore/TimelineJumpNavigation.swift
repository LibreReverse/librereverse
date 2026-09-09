import Foundation

public enum TimelineJumpDirection: Sendable {
    case next
    case previous
}

public enum TimelineJumpOutcome: Sendable {
    case noAction
    case missingValidSeekInterval
    case updateSeekPosition(Date, SeekPositionUpdateSource)
}

/// Selects the neighboring screenshot segment for keyboard navigation.
public enum TimelineJumpNavigation {
    public static let segmentInteriorOffset: TimeInterval = 0.5

    public static func outcome(
        for direction: TimelineJumpDirection,
        anchorDate: Date?,
        processedScreenshotSegments: [TimelineSegment],
        validSeekInterval: DateInterval?
    ) -> TimelineJumpOutcome {
        if case .next = direction, validSeekInterval == nil {
            return .missingValidSeekInterval
        }

        let candidate = candidateSegment(
            for: direction,
            anchorDate: anchorDate,
            processedScreenshotSegments: processedScreenshotSegments
        )

        let target: Date?
        if let candidate {
            target = candidate.startDate.addingTimeInterval(segmentInteriorOffset)
        } else if case .next = direction {
            target = validSeekInterval?.end
        } else {
            target = nil
        }

        guard let target else { return .noAction }
        return .updateSeekPosition(target, .jumpToDate)
    }

    public static func candidateSegment(
        for direction: TimelineJumpDirection,
        anchorDate: Date?,
        processedScreenshotSegments: [TimelineSegment]
    ) -> TimelineSegment? {
        guard !processedScreenshotSegments.isEmpty else { return nil }
        guard let anchorDate else { return processedScreenshotSegments.last }

        // Find the first segment whose end is at or after the requested date.
        var lower = 0
        var upper = processedScreenshotSegments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if anchorDate > processedScreenshotSegments[middle].endDate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let index: Int
        switch direction {
        case .next:
            index = lower + 1
            guard index < processedScreenshotSegments.count else { return nil }
        case .previous:
            index = lower - 1
            // Index zero is excluded by this navigation policy, as is underflow.
            guard index >= 1 else { return nil }
        }
        return processedScreenshotSegments[index]
    }
}
