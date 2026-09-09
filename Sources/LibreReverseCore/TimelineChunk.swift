#if os(macOS) && canImport(AVFoundation)
import Foundation

public struct TimelineSample: Codable, Equatable, Sendable {
    public let wallDate: Date
    public let mediaTime: TimeInterval
}

public struct TimelineChunk: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case clone, historical }
    public let url: URL
    public let startDate: Date
    public let wallEndDate: Date
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let source: Source
    public let samples: [TimelineSample]?
    public let databaseVideoID: Int64?
    public let sampleCount: Int?
    public let startingApplicationBundleID: String?

    public init(
        url: URL,
        startDate: Date,
        wallEndDate: Date,
        duration: TimeInterval,
        width: Int,
        height: Int,
        source: Source,
        samples: [TimelineSample]?,
        databaseVideoID: Int64? = nil,
        sampleCount: Int? = nil,
        startingApplicationBundleID: String? = nil
    ) {
        self.url = url
        self.startDate = startDate
        self.wallEndDate = wallEndDate
        self.duration = duration
        self.width = width
        self.height = height
        self.source = source
        self.samples = samples
        self.databaseVideoID = databaseVideoID
        self.sampleCount = sampleCount
        self.startingApplicationBundleID = startingApplicationBundleID
    }

    public var endDate: Date { wallEndDate }

    public func sample(atOrBefore date: Date) -> TimelineSample? {
        guard let samples else { return nil }
        return samples.last(where: { $0.wallDate <= date })
    }
}

#endif
