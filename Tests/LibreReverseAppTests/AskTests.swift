#if os(macOS)
import XCTest
import LibreReverseCore
@testable import LibreReverseApp

final class AskTests: XCTestCase {
    func testQueryRemovesConversationNoiseAndKeepsUsefulTerms() {
        let query = LibreReverseAskQuery.interpret("What did I promise Acme about the launch yesterday?")
        XCTAssertEqual(query.keywords, ["promise", "acme", "launch"])
        XCTAssertNotNil(query.interval)
    }

    func testYesterdayIsAClosedCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 4, day: 26, hour: 12)
        )!
        let query = LibreReverseAskQuery.interpret("What happened yesterday?", now: now, calendar: calendar)
        let interval = try XCTUnwrap(query.interval)
        XCTAssertEqual(interval.duration, 86_400, accuracy: 0.1)
        XCTAssertTrue(interval.contains(now.addingTimeInterval(-43_200)))
        XCTAssertFalse(interval.contains(now))
    }

    func testCalendarOnlyQuestionsUseTimeWindowEvidenceWithoutLiteralDateKeywords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12)))
        for question in ["What happened this week?", "Summarize last week"]
            + calendar.weekdaySymbols.map({ "What happened \($0)?" }) {
            let query = LibreReverseAskQuery.interpret(question, now: now, calendar: calendar)
            XCTAssertTrue(query.keywords.isEmpty, question)
            XCTAssertNotNil(query.interval, question)
        }
        let topic = LibreReverseAskQuery.interpret("What did Acme decide last week?", now: now, calendar: calendar)
        XCTAssertEqual(topic.keywords, ["acme", "decide"])
        let ordinaryWord = LibreReverseAskQuery.interpret("Summarize week planning", now: now, calendar: calendar)
        XCTAssertNil(ordinaryWord.interval)
        XCTAssertEqual(ordinaryWord.keywords, ["week", "planning"])
        XCTAssertNil(LibreReverseAskQuery.interpret("Search Mondayboard", now: now, calendar: calendar).interval,
            "A weekday substring inside a topic must not impose a time filter")
    }

    func testWeeklyQuestionRetrievesEvidenceThatDoesNotContainCalendarWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let now = Date()
        let calendar = Calendar.current
        // Frame admission follows capture order so adjacent context segments remain valid.
        for (question, text) in [("Summarize last week", "Beta selected the new design."),
                                 ("What happened this week?", "Acme approved the launch.")] {
            let interval = try XCTUnwrap(LibreReverseAskQuery.interpret(question, now: now, calendar: calendar).interval)
            let date = interval.start.addingTimeInterval(600)
            let frame = try LibreReverseLibraryStore.admitFrame(createdAt: date,
                imageFileName: UUID().uuidString + ".png", context: .init(bundleID: "test.editor", windowName: "Project notes"),
                configuration: configuration)
            try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id,
                document: .init(text: text, otherText: "", nodes: []), configuration: configuration)
            let engine = LibreReverseAskEngine(configuration: configuration, provider: AuditEvidenceEchoProvider())
            let answer = try await engine.answer(question: question, apiKey: "synthetic")
            XCTAssertTrue(answer.citations.contains { $0.excerpt == text })
            XCTAssertTrue(answer.text.contains(text))
        }
    }

    func testRedactorRemovesSensitiveTextBeforeProviderBoundary() {
        let redacted = LibreReverseAskRedactor.redact(
            "Email me@example.com or +1 (415) 555-0123 using sk-secret_token_1234567890"
        )
        XCTAssertFalse(redacted.contains("me@example.com"))
        XCTAssertFalse(redacted.contains("555-0123"))
        XCTAssertFalse(redacted.contains("sk-secret"))
        XCTAssertTrue(redacted.contains("[redacted email]"))
        XCTAssertTrue(redacted.contains("[redacted phone]"))
        XCTAssertTrue(redacted.contains("[redacted API token]"))
    }

    func testCopyWithCitationsIncludesReadableMomentAndDeepLink() {
        let answer = LibreReverseAskAnswer(
            text: "The launch moved to Friday. [1]",
            citations: [
                .init(
                    instant: Date(timeIntervalSince1970: 1_777_124_400),
                    title: "Launch review",
                    excerpt: "Move the launch to Friday.",
                    source: "Transcript"
                )
            ]
        )
        XCTAssertTrue(answer.textWithCitations.contains("Moments"))
        XCTAssertTrue(answer.textWithCitations.contains("Launch review"))
        XCTAssertTrue(answer.textWithCitations.contains("librereverse://show-moment?"))
    }

    func testNoResultsCopyPreservesRecoveredGuidance() {
        XCTAssertTrue(
            LibreReverseAskError.noResults.localizedDescription.contains("Rephrase")
        )
        XCTAssertTrue(
            LibreReverseAskError.noResults.localizedDescription.contains("time range")
        )
    }
}
private struct AuditEvidenceEchoProvider: LibreReverseAskAnswerProvider {
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        citations.map(\.excerpt).joined(separator: "\n")
    }
}
#endif
