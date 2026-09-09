import Foundation

/// Applies an asynchronous meeting mutation only to the transcript snapshot
/// that is still presenting the operation's segment. The current snapshot is
/// the merge base so transcription or metadata updates that arrived while the
/// mutation was in flight are never replaced by the older captured value.
public enum LibreReverseMeetingTranscriptMutationResult {
    /// A sheet captures one meeting when it opens, but the timeline can still
    /// change selection through asynchronous playback/search publication. A
    /// destructive or metadata mutation may begin only if that exact meeting
    /// still owns the follower when the user confirms.
    public static func canBegin(
        operationSegmentID: Int64,
        selectedSegmentID: Int64?
    ) -> Bool {
        operationSegmentID == selectedSegmentID
    }

    public static func applyingTitle(
        _ title: String,
        operationSegmentID: Int64,
        to current: LibreReverseMeetingTranscript?
    ) -> LibreReverseMeetingTranscript? {
        guard current?.segmentID == operationSegmentID else { return current }
        return current?.updatingTitle(title)
    }

    public static func applyingContext(
        _ context: LibreReverseMeetingContextUpdate,
        operationSegmentID: Int64,
        to current: LibreReverseMeetingTranscript?
    ) -> LibreReverseMeetingTranscript? {
        guard current?.segmentID == operationSegmentID else { return current }
        return current?.updatingContext(context)
    }

    public static func applyingDeletion(
        operationSegmentID: Int64,
        to current: LibreReverseMeetingTranscript?
    ) -> LibreReverseMeetingTranscript? {
        guard current?.segmentID == operationSegmentID else { return current }
        return nil
    }
}
