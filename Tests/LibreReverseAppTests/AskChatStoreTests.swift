#if os(macOS)
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class AskChatStoreTests: XCTestCase {
    func testEncodedChatPreservesReferencesAndScopeWithoutTranscriptDocuments() throws {
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let scope = LibreReverseAskConversationScope(interval: .init(start: instant, duration: 600), latestSegmentID: 7,
            retrievalQuestion: "What was discussed?", documents: [.init(documentID: -9, segmentID: 7)], requiresFullTranscriptConsent: true)
        let citation = LibreReverseAskCitation(instant: instant, title: "Review", excerpt: "Short source excerpt", source: "Transcript",
            evidence: "FULL_TRANSCRIPT_MUST_NOT_BE_PERSISTED", passageInstant: instant.addingTimeInterval(120))
        let turn = LibreReverseAskSavedTurn(question: "What was discussed?", answer: .init(text: "The plan was staged delivery. [1]",
            citations: [citation], coverageNotes: ["Some archive history was unavailable."], conversationScope: scope))
        let encoded = try LibreReverseAskChatStore.encode([turn])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("FULL_TRANSCRIPT_MUST_NOT_BE_PERSISTED"))
        let restored = try XCTUnwrap(LibreReverseAskChatStore.decode(encoded).first)
        XCTAssertEqual(restored.question, turn.question)
        XCTAssertEqual(restored.answer.text, turn.answer.text)
        XCTAssertEqual(restored.answer.citations.first?.deepLink, citation.deepLink)
        XCTAssertEqual(restored.answer.citations.first?.excerpt, citation.excerpt)
        XCTAssertNil(restored.answer.citations.first?.evidence)
        XCTAssertEqual(restored.answer.coverageNotes, turn.answer.coverageNotes)
        XCTAssertEqual(restored.answer.conversationScope, scope)
    }

    func testSavedChatPreservesMoreThanTwentyTurnsAndRejectsUnsupportedVersion() throws {
        let turns = (0..<24).map { LibreReverseAskSavedTurn(question: "Question \($0)", answer: .init(text: "Answer \($0)", citations: [])) }
        let encoded = try LibreReverseAskChatStore.encode(turns)
        let decoded = try LibreReverseAskChatStore.decode(encoded)
        XCTAssertEqual(decoded.count, 24)
        XCTAssertEqual(decoded.first?.question, "Question 0")
        XCTAssertEqual(decoded.last?.answer.text, "Answer 23")
        XCTAssertThrowsError(try LibreReverseAskChatStore.decode(Data(#"{"version":99,"turns":[]}"#.utf8)))
    }

    func testSavedChatListSupportsBoundedPagesWithoutHidingOlderChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let store = LibreReverseAskChatStore(configuration: configuration)
        let expectedIDs = (0..<3).map { _ in UUID() }
        for (index, id) in expectedIDs.enumerated() {
            try await store.save(id: id, turns: [.init(question: "Chat \(index)", answer: .init(text: "Answer", citations: []))])
        }
        let first = try await store.list(limit: 2, offset: 0)
        let next = try await store.list(limit: 2, offset: 2)
        let end = try await store.list(limit: 2, offset: 4)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(next.count, 1)
        XCTAssertTrue(end.isEmpty)
        XCTAssertEqual(Set((first + next).map(\.id)), Set(expectedIDs))
        do {
            _ = try await store.list(limit: 501)
            XCTFail("Pagination must retain the core's bounded page limit")
        } catch LibreReverseChatStoreError.invalidPagination { }
    }

    func testEncryptedSavedChatSurvivesAdapterRecreationAndCanBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let store = LibreReverseAskChatStore(configuration: configuration)
        let id = UUID()
        let turns = [LibreReverseAskSavedTurn(question: "SYNTHETIC_PRIVATE_CHAT_MARKER", answer: .init(text: "Completed answer", citations: []))]
        try await store.save(id: id, turns: turns)
        let reopened = LibreReverseAskChatStore(configuration: configuration)
        let listed = try await reopened.list()
        XCTAssertEqual(listed.map(\.id), [id])
        let loaded = try await reopened.load(id: id)
        XCTAssertEqual(loaded?.turns, turns)
        for oversized in [
            Array(repeating: turns[0], count: 201),
            [.init(question: "Oversized", answer: .init(text: String(repeating: "x", count: 2 * 1_024 * 1_024), citations: []))]
        ] {
            do {
                try await reopened.save(id: id, turns: oversized)
                XCTFail("An oversized update must not replace the saved conversation")
            } catch LibreReverseAskChatStoreError.conversationLimit { }
            let preserved = try await reopened.load(id: id)
            XCTAssertEqual(preserved?.turns, turns)
        }
        let databaseBytes = try Data(contentsOf: configuration.databaseURL)
        XCTAssertNil(databaseBytes.range(of: Data("SYNTHETIC_PRIVATE_CHAT_MARKER".utf8)))
        try await reopened.delete(id: id)
        let missing = try await store.load(id: id)
        XCTAssertNil(missing)
    }
}
#endif
