#if os(macOS)
import AppKit
import Foundation
import LibreReverseCore

struct LibreReverseAskCitation: Equatable, Sendable {
    let instant: Date
    let title: String
    let excerpt: String
    let source: String

    var deepLink: URL? { MomentDeepLink.url(for: instant) }

    var plainText: String {
        let stamp = Self.timestamp.string(from: instant)
        return "\(stamp) — \(title): \(excerpt)"
    }

    private static let timestamp: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .short
        return value
    }()
}

struct LibreReverseAskAnswer: Equatable, Sendable {
    let text: String
    let citations: [LibreReverseAskCitation]

    var textWithCitations: String {
        guard !citations.isEmpty else { return text }
        return text + "\n\nMoments\n" + citations.enumerated().map {
            let link = $0.element.deepLink?.absoluteString ?? ""
            return "[\($0.offset + 1)] \($0.element.plainText)\(link.isEmpty ? "" : " — \(link)")"
        }.joined(separator: "\n")
    }
}

struct LibreReverseAskQuery: Equatable, Sendable {
    let question: String
    let keywords: [String]
    let interval: DateInterval?

    static func interpret(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> Self {
        let stopWords: Set<String> = [
            "a", "about", "all", "an", "and", "are", "as", "at", "be", "been",
            "between", "based", "but", "by", "can", "did", "do", "does", "for",
            "from", "had", "happen", "happened", "has", "have", "how", "i", "in", "is", "it", "last",
            "me", "my", "of", "on", "or", "our", "please", "said", "that", "the",
            "summary", "summarize", "tell", "this", "to", "today", "was", "we", "were", "what", "when", "where",
            "which", "who", "why", "will", "with", "write", "yesterday", "you",
        ]
        let normalized = question.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        let words = String(normalized).split(whereSeparator: \.isWhitespace).map(String.init)
        let timeRange = inferredTimeRange(in: words, now: now, calendar: calendar)
        var seen: Set<String> = []
        let keywords = words
            .filter { $0.count > 1 && !stopWords.contains($0)
                && !(timeRange?.terms.contains($0) ?? false) && seen.insert($0).inserted }
            .prefix(6)
        return .init(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: Array(keywords),
            interval: timeRange?.interval
        )
    }

    /// Consume the recognized calendar phrase together with its interval.
    /// Date-only questions must use interval evidence, not search for “week”
    /// or a weekday literally inside the recorded text.
    private static func inferredTimeRange(
        in words: [String], now: Date, calendar: Calendar
    ) -> (interval: DateInterval, terms: Set<String>)? {
        if words.contains("today"), let interval = calendar.dateInterval(of: .day, for: now) {
            return (interval, ["today"])
        }
        if words.contains("yesterday"),
           let date = calendar.date(byAdding: .day, value: -1, to: now),
           let interval = calendar.dateInterval(of: .day, for: date) {
            return (interval, ["yesterday"])
        }
        let pairs = zip(words, words.dropFirst())
        if pairs.contains(where: { $0.0 == "this" && $0.1 == "week" }),
           let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
            return (interval, ["this", "week"])
        }
        if pairs.contains(where: { $0.0 == "last" && $0.1 == "week" }),
           let date = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return (interval, ["last", "week"])
        }
        let symbols = calendar.weekdaySymbols.map { $0.lowercased() }
        guard let requested = symbols.firstIndex(where: words.contains) else { return nil }
        let current = calendar.component(.weekday, from: now) - 1
        var daysBack = (current - requested + 7) % 7
        if daysBack == 0 { daysBack = 7 }
        guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now),
              let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
        return (interval, [symbols[requested]])
    }
}

enum LibreReverseAskRedactor {
    static func redact(_ text: String) -> String {
        var value = text
        let patterns = [
            ("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", "[redacted email]"),
            ("(?<![A-Z0-9])(?:sk|rk|pk)-[A-Z0-9_-]{12,}", "[redacted API token]"),
            ("(?<![A-Z0-9])(?:\\+?\\d[\\d(). -]{7,}\\d)(?![A-Z0-9])", "[redacted phone]"),
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: replacement
            )
        }
        return value
    }
}

enum LibreReverseAskError: LocalizedError, Equatable {
    case missingAPIKey
    case emptyQuestion
    case noSearchTerms
    case noResults
    case invalidResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Configure an AI profile in Settings → AI to use Ask LibreReverse."
        case .emptyQuestion:
            "Type a question about anything you've seen, said, or heard."
        case .noSearchTerms:
            "I couldn't find specific terms to search for. Add a person, topic, app, or time frame."
        case .noResults:
            "There are no results for the given time range. Rephrase your question or try a different time range."
        case .invalidResponse:
            "The AI provider returned an answer LibreReverse couldn't read. Please try again."
        case .provider(let message):
            message
        }
    }
}

protocol LibreReverseAskAnswerProvider: Sendable {
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String
}

struct LibreReverseOpenAIResponsesProvider: LibreReverseAskAnswerProvider {
    var model = "gpt-5-mini"
    var session = URLSession.shared

    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let evidence = citations.enumerated().map {
            "[\($0.offset + 1)] \($0.element.plainText)"
        }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 900,
            "instructions": """
                You are Ask LibreReverse, a personal memory assistant. Answer only from the supplied local-history excerpts. Be concise, say when evidence is incomplete, and cite supporting excerpts using [1], [2], etc. Never claim to have seen screenshots, video, or audio.
                """,
            "input": "Question:\n\(question)\n\nLocal-history excerpts:\n\(evidence)",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LibreReverseAskError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let nested = object?["error"] as? [String: Any]
            let message = nested?["message"] as? String
            throw LibreReverseAskError.provider(message ?? "OpenAI request failed (HTTP \(http.statusCode)).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else {
            throw LibreReverseAskError.invalidResponse
        }
        let text = output.compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibreReverseAskError.invalidResponse }
        return text
    }
}

actor LibreReverseAskEngine {
    private let session: LibraryDatabaseSession
    private let provider: any LibreReverseAskAnswerProvider

    init(configuration: LibreReverseLibraryConfiguration, provider: any LibreReverseAskAnswerProvider = LibreReverseOpenAIResponsesProvider()) {
        session = LibraryDatabaseSession(
            configuration: .init(
                databaseURL: configuration.databaseURL,
                keyFileURL: configuration.keyFileURL,
                mediaRoot: configuration.mediaRoot,
                frameImagesRoot: configuration.frameImagesRoot
            )
        )
        self.provider = provider
    }

    func answer(question rawQuestion: String, apiKey: String) async throws -> LibreReverseAskAnswer {
        try Task.checkCancellation()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibreReverseAskError.missingAPIKey
        }
        let query = LibreReverseAskQuery.interpret(rawQuestion)
        guard !query.question.isEmpty else { throw LibreReverseAskError.emptyQuestion }
        var citations: [LibreReverseAskCitation] = []
        var identities: Set<String> = []
        if query.keywords.isEmpty {
            guard let interval = query.interval else { throw LibreReverseAskError.noSearchTerms }
            let candidates = try await session.askEvidenceCandidates(in: interval)
            try Task.checkCancellation()
            let selected: [HistoricalSearchCandidate]
            if candidates.count <= 12 {
                selected = candidates
            } else {
                selected = (0..<12).map { offset in
                    candidates[min(candidates.count - 1, offset * (candidates.count - 1) / 11)]
                }
            }
            for candidate in selected {
                guard let instant = candidate.frameDate else { continue }
                appendCitation(
                    .init(
                        instant: instant,
                        title: candidate.windowName ?? (candidate.segmentType == .audio ? "Meeting" : "Untitled"),
                        excerpt: Self.excerpt(candidate.text, fallback: candidate.otherText),
                        source: candidate.segmentType == .audio ? "Transcript" : "Screen text"
                    ), to: &citations, identities: &identities
                )
            }
        }
        for keyword in query.keywords {
            try Task.checkCancellation()
            let ocr = try await session.recencyOCRSearchResults(query: keyword, amplifiedLimit: 450)
            for item in ocr.filter({ query.interval?.contains($0.result.representativeInstant) ?? true }).prefix(4) {
                appendCitation(
                    .init(
                        instant: item.result.representativeInstant,
                        title: item.result.resolvedTitle,
                        excerpt: Self.excerpt(item.result.candidate.text, fallback: item.result.candidate.otherText),
                        source: "Screen text"
                    ), to: &citations, identities: &identities
                )
            }
            try Task.checkCancellation()
            let transcripts = try await session.recencyTranscriptSearchPage(
                query: keyword, pageSize: 30, amplifiedLimit: 450
            ).results
            try Task.checkCancellation()
            for item in transcripts where query.interval?.contains(item.result.representativeInstant) ?? true {
                appendCitation(
                    .init(
                        instant: item.result.representativeInstant,
                        title: item.result.resolvedTitle,
                        excerpt: Self.excerpt(item.result.transcriptDetails?.transcript ?? "", fallback: ""),
                        source: "Transcript"
                    ), to: &citations, identities: &identities
                )
            }
        }
        citations.sort { $0.instant > $1.instant }
        citations = Array(citations.prefix(12))
        guard !citations.isEmpty else { throw LibreReverseAskError.noResults }
        try Task.checkCancellation()
        let text = try await provider.answer(question: query.question, citations: citations, apiKey: apiKey)
        return .init(text: text, citations: citations)
    }

    private func appendCitation(
        _ citation: LibreReverseAskCitation,
        to values: inout [LibreReverseAskCitation],
        identities: inout Set<String>
    ) {
        let identity = "\(Int(citation.instant.timeIntervalSince1970 / 60))|\(citation.title)|\(citation.excerpt)"
        if identities.insert(identity).inserted { values.append(citation) }
    }

    private static func excerpt(_ text: String, fallback: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return LibreReverseAskRedactor.redact(String(collapsed.prefix(420)))
    }
}

enum LibreReverseAskCredentialStore {
    static var account: String { LibreReverseAIProfiles.selected().credentialAccount }

    static func load(configuration: LibreReverseLibraryConfiguration) throws -> String? {
        if LibreReverseAIProfiles.selected().provider == .local { return "local" }
        guard let data = try LibreReverseArchiveStore.credentialData(account: account, configuration: configuration) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String?, configuration: LibreReverseLibraryConfiguration) throws {
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            try LibreReverseArchiveStore.removeCredentialData(account: account, configuration: configuration)
        } else {
            try LibreReverseArchiveStore.setCredentialData(Data(value.utf8), account: account, configuration: configuration)
        }
    }
}
#endif
