#if os(macOS)
import Foundation

public enum AskEvidenceSource: Sendable { case all, screenText, transcripts }
public struct AskEvidencePage: Sendable {
    public let candidates: [HistoricalSearchCandidate]
    public let hasMore: Bool
}
public struct AskMeetingRecord: Sendable {
    public let segmentID: Int64
    public let documentID: Int64?
    public let start: Date
    public let end: Date
    public let title: String
}
public struct AskMeetingPage: Sendable {
    public let meetings: [AskMeetingRecord]
    public let hasMore: Bool
}
public enum AskTranscriptAvailability: String, Sendable { case missing, pending, failed, archived }
public struct AskMissingTranscript: Sendable {
    public let segmentID: Int64
    public let status: AskTranscriptAvailability
}
public struct AskEvidenceCoverage: Sendable {
    public let unavailableShards: [HistoricalUnavailableShard]
    public let missingTranscripts: [AskMissingTranscript]
    public let hasMoreMeetings: Bool
}
#endif
