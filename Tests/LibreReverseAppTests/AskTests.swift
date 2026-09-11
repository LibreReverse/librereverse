#if os(macOS)
import XCTest
import CSQLCipher
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

    func testAskReadsFullTranscriptOnceAndKeepsReferencePreviewShort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let start = formatter.string(from: day.start.addingTimeInterval(3600))
        let end = formatter.string(from: day.start.addingTimeInterval(7200))
        let body = "Hello. " + String(repeating: "Launch design discussion. ", count: 1900)
            + "FINAL_QUESTION: explain the reservation invariant. Email tail@example.com."
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_close(db) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(db, $0.baseAddress, Int32(key.count)) }, SQLITE_OK)
        let sql = """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
              VALUES(9001,'test.meeting','\(start)','\(end)','Design review',1);
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(9001,'\(body)','','Design review');
            INSERT INTO search(rowid,text,otherText) VALUES(9001,'\(body)','');
            INSERT INTO searchOffsets(rowid,text,otherText) VALUES(9001,'\(body)','');
            INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(9001,9001,NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        // First question shares no search terms with the transcript. Second
        // matches several terms, but must still yield one complete meeting.
        for question in ["Which questions did the interviewer ask in the meeting yesterday?", "What did launch design decide?"] {
            let engine = LibreReverseAskEngine(configuration: configuration, provider: AuditEvidenceEchoProvider())
            let answer = try await engine.answer(question: question, apiKey: "synthetic")
            XCTAssertEqual(answer.citations.count, 1)
            XCTAssertTrue(answer.text.contains("FINAL_QUESTION"), "The answer is beyond the old420-character cut")
            XCTAssertFalse(answer.text.contains("tail@example.com"), "Redaction must cover the full transcript")
            XCTAssertLessThanOrEqual(answer.citations[0].excerpt.count, 420)
            XCTAssertFalse(answer.citations[0].plainText.contains("FINAL_QUESTION"))
        }
        let limited = LibreReverseAskEngine(configuration: configuration, provider: PreviewOnlyEchoProvider())
        let preview = try await limited.answer(question: "What happened yesterday?", apiKey: "synthetic")
        XCTAssertFalse(preview.text.contains("FINAL_QUESTION"), "Unconsented providers receive only previews")
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
    var allowsFullTranscriptEvidence: Bool { true }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        citations.map { $0.evidence ?? $0.excerpt }.joined(separator: "\n")
    }
}
private struct PreviewOnlyEchoProvider: LibreReverseAskAnswerProvider {
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        citations.map { $0.evidence ?? $0.excerpt }.joined(separator: "\n")
    }
}
#endif
