#if os(macOS)
import Foundation
import LibreReverseCore

struct LibreReverseAskSavedTurn: Equatable, Sendable {
    let question: String
    let answer: LibreReverseAskAnswer
}

struct LibreReverseAskSavedChat: Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let turns: [LibreReverseAskSavedTurn]
}

struct LibreReverseAskChatSummary: Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

enum LibreReverseAskChatStoreError: LocalizedError {
    case invalidSavedChat
    case conversationLimit
    var errorDescription: String? {
        switch self {
        case .invalidSavedChat: "This saved conversation could not be read. Its stored data has been preserved."
        case .conversationLimit: "This conversation exceeds the saved-chat limit of 200 exchanges or 2 MiB. Start a new chat to continue. Previously saved exchanges have been preserved."
        }
    }
}

/// Performs encrypted catalog I/O away from the main actor. Only completed
/// exchanges are accepted; full source documents are intentionally not encoded.
actor LibreReverseAskChatStore {
    private let configuration: LibreReverseLibraryConfiguration
    init(configuration: LibreReverseLibraryConfiguration) { self.configuration = configuration }

    func list(limit: Int = 100, offset: Int = 0) throws -> [LibreReverseAskChatSummary] {
        try LibreReverseChatStore.list(limit: limit, offset: offset, configuration: configuration).map {
            guard let id = UUID(uuidString: $0.id) else { throw LibreReverseAskChatStoreError.invalidSavedChat }
            return .init(id: id, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    func load(id: UUID) throws -> LibreReverseAskSavedChat? {
        guard let stored = try LibreReverseChatStore.load(id: id.uuidString, configuration: configuration) else { return nil }
        let turns = try Self.decode(stored.payload)
        return .init(id: id, title: stored.summary.title, updatedAt: stored.summary.updatedAt, turns: turns)
    }

    func save(id: UUID, turns: [LibreReverseAskSavedTurn]) throws {
        guard !turns.isEmpty else { return }
        let payload = try Self.encode(turns)
        let title = String(turns.first!.question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        _ = try LibreReverseChatStore.save(id: id.uuidString, title: title.isEmpty ? "Conversation" : title,
            payload: payload, configuration: configuration)
    }

    func delete(id: UUID) throws {
        try LibreReverseChatStore.delete(id: id.uuidString, configuration: configuration)
    }

    nonisolated static func encode(_ turns: [LibreReverseAskSavedTurn]) throws -> Data {
        guard turns.count <= 200 else { throw LibreReverseAskChatStoreError.conversationLimit }
        let envelope = Envelope(version: 1, turns: turns.map(Turn.init))
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= LibreReverseChatStore.maximumPayloadBytes else { throw LibreReverseAskChatStoreError.conversationLimit }
        return data
    }

    nonisolated static func decode(_ data: Data) throws -> [LibreReverseAskSavedTurn] {
        guard data.count <= LibreReverseChatStore.maximumPayloadBytes else { throw LibreReverseAskChatStoreError.invalidSavedChat }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.turns.count <= 200,
              envelope.turns.allSatisfy({ $0.citations.count <= 112 && ($0.scope?.documents.count ?? 0) <= 112 }) else {
            throw LibreReverseAskChatStoreError.invalidSavedChat
        }
        return envelope.turns.map(\.value)
    }

    private struct Envelope: Codable { let version: Int; let turns: [Turn] }
    private struct Turn: Codable {
        let question: String
        let text: String
        let citations: [Citation]
        let coverageNotes: [String]
        let scope: Scope?
        init(_ turn: LibreReverseAskSavedTurn) {
            question = turn.question; text = turn.answer.text
            citations = turn.answer.citations.map(Citation.init)
            coverageNotes = turn.answer.coverageNotes
            scope = turn.answer.conversationScope.map(Scope.init)
        }
        var value: LibreReverseAskSavedTurn {
            .init(question: question, answer: .init(text: text, citations: citations.map(\.value),
                coverageNotes: coverageNotes, conversationScope: scope?.value))
        }
    }
    private struct Citation: Codable {
        let instant: Date
        let title: String
        let excerpt: String
        let source: String
        let passageInstant: Date?
        init(_ citation: LibreReverseAskCitation) {
            instant = citation.instant; title = citation.title; excerpt = citation.excerpt
            source = citation.source; passageInstant = citation.passageInstant
        }
        var value: LibreReverseAskCitation {
            .init(instant: instant, title: title, excerpt: excerpt, source: source, passageInstant: passageInstant)
        }
    }
    private struct Scope: Codable {
        struct Document: Codable { let documentID: Int64; let segmentID: Int64 }
        let interval: DateInterval?
        let latestSegmentID: Int64?
        let retrievalQuestion: String
        let documents: [Document]
        let requiresFullTranscriptConsent: Bool
        init(_ scope: LibreReverseAskConversationScope) {
            interval = scope.interval; latestSegmentID = scope.latestSegmentID
            retrievalQuestion = scope.retrievalQuestion
            documents = scope.documents.map { .init(documentID: $0.documentID, segmentID: $0.segmentID) }
            requiresFullTranscriptConsent = scope.requiresFullTranscriptConsent
        }
        var value: LibreReverseAskConversationScope {
            .init(interval: interval, latestSegmentID: latestSegmentID, retrievalQuestion: retrievalQuestion,
                documents: documents.map { .init(documentID: $0.documentID, segmentID: $0.segmentID) },
                requiresFullTranscriptConsent: requiresFullTranscriptConsent)
        }
    }
}
#endif
