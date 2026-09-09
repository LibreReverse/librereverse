import Foundation

public enum LibreReverseMeetingTranscriptInteraction: Equatable, Sendable {
    case userTextSelection
    case programmaticWordFollow
}

public enum LibreReverseMeetingTranscriptInteractionPolicy {
    /// The follower must rebuild when any word-level presentation fact changes,
    /// even if the canonical full text is identical. In particular, a retry or
    /// imported repair may correct source labels, clocks, or links in place.
    /// Header-only metadata changes deliberately do not rebuild the native text
    /// view, because doing so would destroy an unrelated user selection.
    public static func requiresTextRebuild(
        previous: LibreReverseMeetingTranscript?,
        next: LibreReverseMeetingTranscript
    ) -> Bool {
        previous?.segmentID != next.segmentID
            || previous?.text != next.text
            || previous?.words != next.words
            || previous?.processingState != next.processingState
    }

    /// User selection must retain ownership of the text view. Programmatic
    /// active-word following remains part of playback and does not interrupt it.
    public static func interruptsPlayback(
        _ interaction: LibreReverseMeetingTranscriptInteraction
    ) -> Bool {
        interaction == .userTextSelection
    }

    /// Produces only ranges that are safe to pass into AppKit attributed-string
    /// APIs. Historical databases are user-owned input: malformed offsets must
    /// omit one link rather than trap the entire timeline while rendering.
    public static func linkRange(
        fullTextUTF16Length: Int,
        wordTextUTF16Length: Int,
        offset: Int?
    ) -> NSRange? {
        guard fullTextUTF16Length >= 0,
            wordTextUTF16Length > 0,
            let offset,
            offset >= 0,
            offset <= fullTextUTF16Length,
            wordTextUTF16Length <= fullTextUTF16Length - offset
        else { return nil }
        return NSRange(location: offset, length: wordTextUTF16Length)
    }
}
