import Foundation

public enum LibreReverseMeetingTranscriptExport {
    public enum LosslessJSONError: Error, Equatable, Sendable {
        case invalidSchema(String)
        case unsupportedVersion(Int)
        case invalidDate(String)
        case invalidProvider(String)
        case invalidSource(String)
        case invalidProcessingState(String)
        case invalidRetryState
        case invalidSegmentID(Int64)
        case invalidDateRange
        case invalidWordIdentity(Int)
        case invalidWordTiming(Int)
        case invalidWordOrder(Int)
        case invalidWordOffset(Int)
    }

    public enum Format: String, CaseIterable, Equatable, Sendable {
        case plainText
        case webVTT
        case losslessJSON

        public var filenameExtension: String {
            switch self {
            case .plainText: "txt"
            case .webVTT: "vtt"
            case .losslessJSON: "json"
            }
        }
    }

    public static func plainText(_ transcript: LibreReverseMeetingTranscript) -> String {
        let title = transcript.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.isEmpty ? "Meeting transcript" : title
        let duration = max(0, transcript.endDate.timeIntervalSince(transcript.startDate))
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        var details = [
            "\(iso8601.string(from: transcript.startDate)) – \(iso8601.string(from: transcript.endDate))",
            "Duration: \(minutes)m \(String(format: "%02d", seconds))s",
        ]
        if let provider = transcript.metadata.provider {
            details.append("Provider: \(provider.displayName)")
        }
        if let calendarTitle = transcript.metadata.calendarTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !calendarTitle.isEmpty
        {
            details.append("Calendar: \(calendarTitle)")
        }
        if !transcript.metadata.participants.isEmpty {
            details.append(
                "Participants: \(transcript.metadata.participants.joined(separator: ", "))")
        }
        return """
            \(heading)
            \(details.joined(separator: "\n"))

            \(transcript.text)
            """
    }

    public static func webVTT(_ transcript: LibreReverseMeetingTranscript) -> String {
        var lines = ["WEBVTT", "", "NOTE"]
        lines.append("Title: \(singleLine(transcript.title))")
        lines.append("Start: \(iso8601.string(from: transcript.startDate))")
        lines.append("End: \(iso8601.string(from: transcript.endDate))")
        if let provider = transcript.metadata.provider {
            lines.append("Provider: \(singleLine(provider.displayName))")
        }
        if let calendarTitle = transcript.metadata.calendarTitle,
            !calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.append("Calendar: \(singleLine(calendarTitle))")
        }
        if !transcript.metadata.participants.isEmpty {
            lines.append(
                "Participants: \(singleLine(transcript.metadata.participants.joined(separator: ", ")))"
            )
        }
        for (index, word) in transcript.words.enumerated() {
            guard let cueTimes = webVTTCueTimes(word) else { continue }
            lines.append("")
            lines.append("word-\(index)-\(word.id)")
            lines.append("\(cueTimes.start) --> \(cueTimes.end)")
            lines.append(webVTTCueText(word.text))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func data(
        _ transcript: LibreReverseMeetingTranscript,
        format: Format
    ) throws -> Data {
        switch format {
        case .plainText:
            return Data(plainText(transcript).utf8)
        case .webVTT:
            return Data(webVTT(transcript).utf8)
        case .losslessJSON:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(LosslessEnvelope(transcript))
        }
    }

    public static func transcript(fromLosslessJSON data: Data) throws
        -> LibreReverseMeetingTranscript
    {
        try JSONDecoder().decode(LosslessEnvelope.self, from: data).transcript()
    }

    public static func format(for url: URL) -> Format? {
        switch url.pathExtension.lowercased() {
        case "txt": .plainText
        case "vtt": .webVTT
        case "json": .losslessJSON
        default: nil
        }
    }

    public static func suggestedFileName(
        _ transcript: LibreReverseMeetingTranscript,
        format: Format = .plainText
    ) -> String {
        let title = transcript.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let basis = title.isEmpty ? "Meeting transcript" : title
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let safe = basis.components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Meeting transcript" : safe) + ".\(format.filenameExtension)"
    }

    private struct LosslessEnvelope: Codable {
        let schema: String
        let version: Int
        let segmentID: Int64
        let title: String
        let text: String
        let startDate: String
        let endDate: String
        let metadata: Metadata
        let processing: Processing
        let words: [Word]

        init(_ transcript: LibreReverseMeetingTranscript) {
            schema = "librereverse.meeting-transcript"
            version = 1
            segmentID = transcript.segmentID
            title = transcript.title
            text = transcript.text
            startDate = iso8601.string(from: transcript.startDate)
            endDate = iso8601.string(from: transcript.endDate)
            metadata = Metadata(transcript.metadata)
            processing = Processing(transcript.processingState)
            words = transcript.words.map(Word.init)
        }

        func transcript() throws -> LibreReverseMeetingTranscript {
            guard schema == "librereverse.meeting-transcript" else {
                throw LosslessJSONError.invalidSchema(schema)
            }
            guard version == 1 else {
                throw LosslessJSONError.unsupportedVersion(version)
            }
            guard let decodedStart = iso8601.date(from: startDate) else {
                throw LosslessJSONError.invalidDate(startDate)
            }
            guard let decodedEnd = iso8601.date(from: endDate) else {
                throw LosslessJSONError.invalidDate(endDate)
            }
            guard segmentID > 0 else {
                throw LosslessJSONError.invalidSegmentID(segmentID)
            }
            guard decodedEnd >= decodedStart else {
                throw LosslessJSONError.invalidDateRange
            }
            let decodedWords = try validatedWords(fullTextUTF16Count: text.utf16.count)
            return try .init(
                segmentID: segmentID,
                title: title,
                text: text,
                startDate: decodedStart,
                endDate: decodedEnd,
                words: decodedWords,
                metadata: metadata.transcriptMetadata(),
                processingState: processing.transcriptProcessingState()
            )
        }

        private func validatedWords(fullTextUTF16Count: Int) throws
            -> [LibreReverseMeetingTranscriptWord]
        {
            var priorStart: TimeInterval?
            var priorOffset: Int?
            for (index, word) in words.enumerated() {
                guard word.id > 0 else {
                    throw LosslessJSONError.invalidWordIdentity(index)
                }
                guard word.startSeconds.isFinite, word.durationSeconds.isFinite,
                    word.startSeconds >= 0, word.durationSeconds >= 0
                else {
                    throw LosslessJSONError.invalidWordTiming(index)
                }
                if let priorStart, word.startSeconds < priorStart {
                    throw LosslessJSONError.invalidWordOrder(index)
                }
                if let offset = word.fullTextUTF16Offset {
                    guard offset >= 0, offset <= fullTextUTF16Count else {
                        throw LosslessJSONError.invalidWordOffset(index)
                    }
                    if let priorOffset, offset < priorOffset {
                        throw LosslessJSONError.invalidWordOffset(index)
                    }
                    priorOffset = offset
                }
                priorStart = word.startSeconds
            }
            return words.map(\.transcriptWord)
        }
    }

    private struct Metadata: Codable {
        let provider: String?
        let source: String?
        let calendarTitle: String?
        let participants: [String]
        let calendarID: String?
        let calendarEventID: String?
        let calendarSeriesID: String?

        init(_ metadata: LibreReverseMeetingTranscriptMetadata) {
            provider = metadata.provider?.legacyPersistenceValue
            source = metadata.source?.rawValue
            calendarTitle = metadata.calendarTitle
            participants = metadata.participants
            calendarID = metadata.calendarID
            calendarEventID = metadata.calendarEventID
            calendarSeriesID = metadata.calendarSeriesID
        }

        func transcriptMetadata() throws -> LibreReverseMeetingTranscriptMetadata {
            let decodedProvider: LibreReverseMeetingProvider?
            if let provider {
                guard let value = LibreReverseMeetingProvider(persistedValue: provider) else {
                    throw LosslessJSONError.invalidProvider(provider)
                }
                decodedProvider = value
            } else {
                decodedProvider = nil
            }
            let decodedSource: LibreReverseMeetingCandidateSource?
            if let source {
                guard let value = LibreReverseMeetingCandidateSource(rawValue: source) else {
                    throw LosslessJSONError.invalidSource(source)
                }
                decodedSource = value
            } else {
                decodedSource = nil
            }
            return .init(
                provider: decodedProvider,
                source: decodedSource,
                calendarTitle: calendarTitle,
                participants: participants,
                calendarID: calendarID,
                calendarEventID: calendarEventID,
                calendarSeriesID: calendarSeriesID
            )
        }
    }

    private struct Processing: Codable {
        let state: String
        let attempt: Int?
        let retryAfter: String?

        init(_ processingState: LibreReverseMeetingTranscriptProcessingState) {
            switch processingState {
            case .unavailable:
                state = "unavailable"
                attempt = nil
                retryAfter = nil
            case .queued:
                state = "queued"
                attempt = nil
                retryAfter = nil
            case .retrying(let attempt, let date):
                state = "retrying"
                self.attempt = attempt
                retryAfter = date.map { iso8601.string(from: $0) }
            case .complete:
                state = "complete"
                attempt = nil
                retryAfter = nil
            }
        }

        func transcriptProcessingState() throws -> LibreReverseMeetingTranscriptProcessingState {
            switch state {
            case "unavailable":
                guard attempt == nil, retryAfter == nil else {
                    throw LosslessJSONError.invalidRetryState
                }
                return .unavailable
            case "queued":
                guard attempt == nil, retryAfter == nil else {
                    throw LosslessJSONError.invalidRetryState
                }
                return .queued
            case "complete":
                guard attempt == nil, retryAfter == nil else {
                    throw LosslessJSONError.invalidRetryState
                }
                return .complete
            case "retrying":
                guard let attempt, attempt > 0 else {
                    throw LosslessJSONError.invalidRetryState
                }
                let decodedRetry: Date?
                if let retryAfter {
                    guard let value = iso8601.date(from: retryAfter) else {
                        throw LosslessJSONError.invalidDate(retryAfter)
                    }
                    decodedRetry = value
                } else {
                    decodedRetry = nil
                }
                return .retrying(attempt: attempt, retryAfter: decodedRetry)
            default:
                throw LosslessJSONError.invalidProcessingState(state)
            }
        }
    }

    private struct Word: Codable {
        let id: Int64
        let speechSource: String
        let text: String
        let startSeconds: TimeInterval
        let durationSeconds: TimeInterval
        let fullTextUTF16Offset: Int?

        init(_ word: LibreReverseMeetingTranscriptWord) {
            id = word.id
            speechSource = word.speechSource
            text = word.text
            startSeconds = word.startSeconds
            durationSeconds = word.durationSeconds
            fullTextUTF16Offset = word.fullTextUTF16Offset
        }

        var transcriptWord: LibreReverseMeetingTranscriptWord {
            .init(
                id: id,
                speechSource: speechSource,
                text: text,
                startSeconds: startSeconds,
                durationSeconds: durationSeconds,
                fullTextUTF16Offset: fullTextUTF16Offset
            )
        }
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func webVTTCueText(_ value: String) -> String {
        singleLine(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "--&gt;", with: "→")
    }

    private static func webVTTCueTimes(
        _ word: LibreReverseMeetingTranscriptWord
    ) -> (start: String, end: String)? {
        guard word.id > 0,
            word.startSeconds.isFinite,
            word.durationSeconds.isFinite,
            word.startSeconds >= 0,
            word.durationSeconds >= 0,
            word.startSeconds <= maximumWebVTTSeconds,
            word.durationSeconds <= maximumWebVTTSeconds - word.startSeconds
        else { return nil }
        let declaredEnd = word.startSeconds + word.durationSeconds
        let minimumEnd = word.startSeconds + 0.001
        guard declaredEnd.isFinite, minimumEnd.isFinite, minimumEnd > word.startSeconds else {
            return nil
        }
        let end = max(minimumEnd, declaredEnd)
        guard end <= maximumWebVTTSeconds else { return nil }
        return (webVTTTime(word.startSeconds), webVTTTime(end))
    }

    private static func webVTTTime(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02d:%02d:%02d.%03d",
            hours,
            minutes,
            wholeSeconds,
            remainder
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // Keep conversion comfortably below Int.max even after Double rounding.
    // This is still more than 146 million years of WebVTT time.
    private static let maximumWebVTTSeconds = Double(Int.max / 2_000)
}
