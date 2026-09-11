#if os(macOS)
import XCTest
import CSQLCipher
import LibreReverseCore
@testable import LibreReverseApp

final class AskRetrievalTests: XCTestCase {
    func testConversationRereadsWholeMeetingAndKeepsResolvedDateAcrossMidnight() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday", now: now).interval)
        let fullText = String(repeating: "Opening discussion. ", count: 100) + "TAIL_QUESTION about the delivery schedule."
        try fixture.meeting(id: 9001, start: day.start.addingTimeInterval(3600), text: fullText)
        try fixture.meeting(id: 9002, start: day.end.addingTimeInterval(3600), text: "OTHER_DAY should not be included.")
        let provider = ConversationProvider()
        let engine = LibreReverseAskEngine(configuration: fixture.configuration, provider: provider)
        let initial = "What questions were asked in the meeting yesterday?"
        let first = try await engine.answer(question: initial, apiKey: "synthetic", now: now)
        let followup = try await engine.answer(question: "What did he ask next?",
            conversation: [.init(question: initial, answer: "PRIOR_REPLY about the opening question [1]", scope: first.conversationScope)],
            apiKey: "synthetic", now: now.addingTimeInterval(172_800))
        XCTAssertEqual(followup.conversationScope?.interval, first.conversationScope?.interval)
        XCTAssertEqual(followup.citations.count, 1)
        XCTAssertTrue(followup.citations[0].evidence?.contains("TAIL_QUESTION") == true)
        let prompt = await provider.lastQuestion
        XCTAssertTrue(prompt.contains(initial))
        XCTAssertTrue(prompt.contains("PRIOR_REPLY"))
        XCTAssertTrue(prompt.contains("not evidence"))
        XCTAssertTrue(prompt.contains("What did he ask next?"))
        XCTAssertFalse(followup.text.contains("OTHER_DAY"))
        // An explicit new day overrides the frozen initial day and its documents.
        let override = try await engine.answer(question: "What about the meeting today?",
            conversation: [.init(question: initial, answer: first.text, scope: first.conversationScope)],
            apiKey: "synthetic", now: now)
        XCTAssertTrue(override.text.contains("OTHER_DAY"))
        XCTAssertFalse(override.text.contains("TAIL_QUESTION"))
        XCTAssertTrue(override.conversationScope?.retrievalQuestion.contains("today") == true)
        XCTAssertFalse(override.conversationScope?.retrievalQuestion.contains("yesterday") == true)
        let latest = try await engine.answer(question: "Summarize the latest meeting",
            conversation: [.init(question: initial, answer: first.text, scope: first.conversationScope)],
            apiKey: "synthetic", now: now)
        XCTAssertTrue(latest.text.contains("OTHER_DAY"))
        XCTAssertFalse(latest.text.contains("TAIL_QUESTION"))
        XCTAssertEqual(latest.conversationScope?.retrievalQuestion, "Summarize the latest meeting")
        // A fresh conversation must have no inherited dates or source identities.
        do {
            _ = try await engine.answer(question: "What did he ask next?", apiKey: "synthetic", now: now)
            XCTFail("A new question must not inherit the previous meeting")
        } catch LibreReverseAskError.noResults { }
    }

    func testViewingMomentScopesOnlyExplicitDeicticRequestAndKeepsConversationScope() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let view = Date().addingTimeInterval(-3600)
        try fixture.screen("SELECTED_VIEW synthetic project page", at: view)
        try fixture.screen("OUTSIDE_VIEW unrelated page", at: view.addingTimeInterval(3600))
        let engine = LibreReverseAskEngine(configuration: fixture.configuration, provider: EchoProvider())
        let answer = try await engine.answer(question: "What was on screen here?", apiKey: "synthetic", viewingInstant: view)
        XCTAssertTrue(answer.text.contains("SELECTED_VIEW"))
        XCTAssertFalse(answer.text.contains("OUTSIDE_VIEW"))
        XCTAssertEqual(answer.conversationScope?.interval, DateInterval(start: view.addingTimeInterval(-300), duration: 600))
        let followup = try await engine.answer(question: "Explain that",
            conversation: [.init(question: "What was on screen here?", answer: answer.text, scope: answer.conversationScope)],
            apiKey: "synthetic", viewingInstant: view.addingTimeInterval(3600))
        XCTAssertEqual(followup.conversationScope?.interval, answer.conversationScope?.interval)
        XCTAssertTrue(followup.text.contains("SELECTED_VIEW"))
        XCTAssertFalse(followup.text.contains("OUTSIDE_VIEW"))
        let unscoped = try await engine.answer(question: "Find unrelated", apiKey: "synthetic", viewingInstant: view)
        XCTAssertTrue(unscoped.text.contains("OUTSIDE_VIEW"))
        XCTAssertNil(unscoped.conversationScope?.interval)
    }

    func testLargeContextFollowupKeepsCompleteEighteenQuestionAnswer() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        try fixture.meeting(id: 9001, start: day.start.addingTimeInterval(3600), text: "Persisted source: the final interview question was about staged delivery and validation.")
        let scope = LibreReverseAskConversationScope(interval: day, latestSegmentID: nil,
            retrievalQuestion: "List all interview questions from the meeting yesterday", documents: [.init(documentID: 9001, segmentID: 9001)], requiresFullTranscriptConsent: true)
        let questions = (1...18).map { number in
            "\(number). How would you approach engineering problem \(number)? Explain the requirements you would clarify, the constraints you would consider, the alternatives you would compare, and the validation you would require before committing to staged delivery. [1]"
        }.joined(separator: "\n\n")
        XCTAssertGreaterThan(questions.utf8.count, 4_000)
        let turns = [LibreReverseAskConversationTurn(question: "Earlier context", answer: String(repeating: "Older generated reply. ", count: 3000), scope: scope),
            .init(question: scope.retrievalQuestion, answer: questions, scope: scope)]
        let provider = ConversationProvider()
        _ = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: provider)
            .answer(question: "Expand question 18", conversation: turns, apiKey: "synthetic")
        let prompt = await provider.lastQuestion
        XCTAssertTrue(prompt.contains(questions), "The complete newest answer must survive, including the late numbered question")
        XCTAssertTrue(prompt.contains("Current question:\nExpand question 18"))
        XCTAssertTrue(prompt.contains("Prior answer truncated for context"), "Older oversized replies must be explicitly marked")
        XCTAssertLessThan(prompt.utf8.count, 25_000)
    }

    func testLongConversationLeavesEvidenceRoomInSmallModelContext() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        try fixture.meeting(id: 9001, start: day.start.addingTimeInterval(3600), text: "The next question concerned delivery dates.")
        let scope = LibreReverseAskConversationScope(interval: day, latestSegmentID: nil,
            retrievalQuestion: "What happened in the meeting yesterday?",
            documents: [.init(documentID: 9001, segmentID: 9001)], requiresFullTranscriptConsent: true)
        let turn = LibreReverseAskConversationTurn(question: scope.retrievalQuestion,
            answer: "Earlier answer. " + String(repeating: "Long discussion details. ", count: 3000), scope: scope)
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: SmallConversationProvider())
            .answer(question: "What did he ask next?", conversation: [turn], apiKey: "synthetic")
        XCTAssertTrue(answer.text.contains("delivery dates"))
    }

    func testConversationContextIsBoundedAndHonorsCurrentRouteConsent() {
        let scope = LibreReverseAskConversationScope(interval: nil, latestSegmentID: nil,
            retrievalQuestion: "Meeting", documents: [], requiresFullTranscriptConsent: true)
        let turns = (0..<20).map { LibreReverseAskConversationTurn(question: "Question \($0)",
            answer: "PRIVATE_DERIVED_REPLY " + String(repeating: "🧑🏽‍💻", count: 2000), scope: scope) }
        let authorized = LibreReverseAskEngine.conversationContext(turns, permitsFullTranscriptContext: true, byteLimit: 1200)
        XCTAssertLessThanOrEqual(authorized.utf8.count, 1200)
        XCTAssertTrue(authorized.contains("Question 19"))
        XCTAssertTrue(authorized.contains("Prior answer truncated for context"))
        XCTAssertFalse(authorized.contains("Question 0\n"))
        let denied = LibreReverseAskEngine.conversationContext(turns, permitsFullTranscriptContext: false)
        XCTAssertFalse(denied.contains("PRIVATE_DERIVED_REPLY"))
        XCTAssertTrue(denied.contains("Prior answer omitted"))
        XCTAssertEqual(LibreReverseAskEngine.conversationContext([], permitsFullTranscriptContext: true), "")
    }

    func testMeetingQuestionKeepsFullTranscriptAndExcludesDistractingScreenMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        let body = "Opening question. " + String(repeating: "Discussion of engineering systems. ", count: 1000) + "FINAL_FOLLOWUP: What did you choose not to build?"
        try fixture.meeting(id: 9001, start: day.start.addingTimeInterval(3600), text: body)
        try fixture.screen("Interview questions for unrelated job postings.", at: day.start.addingTimeInterval(7200))
        let progress = ProgressRecorder()
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: PlanningProvider(plans: [#"{"operations":[]}"#]))
            .answer(question: "What questions did the interviewer ask in the meeting yesterday?", apiKey: "synthetic", onProgress: { progress.record($0) })
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertEqual(answer.citations.first?.source, "Transcript")
        XCTAssertTrue(answer.text.contains("FINAL_FOLLOWUP"))
        XCTAssertFalse(answer.text.contains("unrelated job"))
        XCTAssertFalse(answer.text.hasPrefix("Coverage:"))
        XCTAssertTrue(progress.values.contains { $0.contains("Reading the full transcript") })
        XCTAssertTrue(progress.values.contains { $0.contains("another lookup") })
        XCTAssertEqual(progress.values.last, "Answer ready.")
    }

    func testPlannerRejectsUnboundedOrInvalidOperations() throws {
        let parse = LibreReverseAskRetrievalPlanner.parse
        XCTAssertEqual(try parse(#"{"operations":[{"tool":"read","sourceID":"d-1_s2"}]}"#).first?.sourceID, "d-1_s2")
        XCTAssertEqual(try parse("```json\n{\"operations\":[]}\n```"), [])
        for value in [
            #"{"operations":[{"tool":"read","sourceID":"../../secret"}]}"#,
            #"{"operations":[{"tool":"read","sourceID":"d1_s2","startSeconds":-1,"endSeconds":10}]}"#,
            #"{"operations":[{"tool":"search","query":""}]}"#,
            #"{"operations":[{"tool":"delete","sourceID":"d1_s2"}]}"#,
            "{\"operations\":[" + Array(repeating: "{\"tool\":\"listMeetings\"}", count: 5).joined(separator: ",") + "]}"
        ] { XCTAssertThrowsError(try parse(value)) }
    }

    func testMatchingPassageIncludesTailAndPreservesUnicodeBoundaries() {
        let text = String(repeating: "Unrelated introductory material. ", count: 100)
            + "改訂 🧑🏽‍💻 Budget48217 was approved after the capacity review."
        let preview = LibreReverseAskPassage.preview(text, terms: ["budget48217", "capacity"])
        XCTAssertTrue(preview.contains("Budget48217"))
        XCTAssertTrue(preview.contains("capacity review"))
        XCTAssertLessThanOrEqual(preview.count, 420)
    }

    func testFollowupSearchFindsSecondSourceWithoutOriginalQueryWords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.screen("We must improve capacity next quarter.", at: Date().addingTimeInterval(-120))
        try fixture.screen("Resharding uses tenant partitions; the owner is Ada.", at: Date().addingTimeInterval(-60))
        let provider = PlanningProvider(plans: [#"{"operations":[{"tool":"search","query":"resharding"}]}"#, #"{"operations":[]}"#])
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: provider)
            .answer(question: "How will we improve capacity?", apiKey: "synthetic")
        XCTAssertTrue(answer.text.contains("tenant partitions"))
        XCTAssertTrue(answer.text.contains("capacity next quarter"))
        let calls = await provider.planningCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(answer.citations.count, 2)
    }

    func testListThenReadGetsWholeTranscriptWithoutKeywordOverlap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = String(repeating: "Introductory remarks. ", count: 100) + "Ada owns tenant partitioning."
        try fixture.meeting(id: 9001, start: Date().addingTimeInterval(-3600), text: body)
        let provider = PlanningProvider(plans: [#"{"operations":[{"tool":"listMeetings"}]}"#,
            #"{"operations":[{"tool":"read","sourceID":"d9001_s9001"}]}"#])
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: provider)
            .answer(question: "Explain responsibility", apiKey: "synthetic")
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertTrue(answer.text.contains("Ada owns tenant partitioning"))
        XCTAssertFalse(answer.citations[0].excerpt.contains("Ada owns"))
    }

    func testExpansionIncludesNeighborWithinOriginalDateScope() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        try fixture.screen("Outside the requested day.", at: day.start.addingTimeInterval(-15))
        try fixture.screen("Capacity review anchor.", at: day.start.addingTimeInterval(15))
        try fixture.screen("Ada owns tenant partitions.", at: day.start.addingTimeInterval(30))
        let session = LibraryDatabaseSession(configuration: .init(databaseURL: fixture.configuration.databaseURL,
            keyFileURL: fixture.configuration.keyFileURL, mediaRoot: fixture.configuration.mediaRoot))
        let page = try await session.askSearchEvidence(query: "capacity", in: day, source: .screenText)
        let candidate = try XCTUnwrap(page.candidates.first)
        let id = LibreReverseAskRetrievalPlanner.sourceID(candidate)
        let plan = "{\"operations\":[{\"tool\":\"expand\",\"sourceID\":\"\(id)\"}]}"
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: PlanningProvider(plans: [plan, #"{"operations":[]}"#]))
            .answer(question: "Compare capacity yesterday", apiKey: "synthetic")
        XCTAssertTrue(answer.text.contains("Ada owns"))
        XCTAssertFalse(answer.text.contains("Outside the requested"))
        XCTAssertEqual(answer.citations.count, 2)
    }

    func testDateScopedScreenSearchUsesMatchPassagesAndDistinctDocuments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        try fixture.screen(String(repeating: "Introduction. ", count: 100) + "Budget approved for project Alpha.", at: day.start.addingTimeInterval(3600))
        try fixture.screen(String(repeating: "Introduction. ", count: 100) + "Budget rejected for project Beta.", at: day.start.addingTimeInterval(3605))
        try fixture.screen("Budget today should not appear.", at: Date())
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: PlanningProvider(plans: []))
            .answer(question: "What budget yesterday?", apiKey: "synthetic")
        XCTAssertEqual(answer.citations.count, 2)
        XCTAssertTrue(answer.text.contains("Alpha"))
        XCTAssertTrue(answer.text.contains("Beta"))
        XCTAssertFalse(answer.text.contains("today should"))
    }

    func testRepeatedScreenPassagesUseOneReference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        let common = "Budget48217 approved. " + String(repeating: "Unrelated filler. ", count: 100)
        try fixture.screen(common + "Footer A", at: day.start.addingTimeInterval(3600))
        try fixture.screen(common + "Footer B", at: day.start.addingTimeInterval(3605))
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: EchoProvider())
            .answer(question: "What budget48217 yesterday?", apiKey: "synthetic")
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertTrue(answer.text.contains("Budget48217 approved"))
    }

    func testMissingTranscriptProducesCoverageInsteadOfUnqualifiedNoResults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day = try XCTUnwrap(LibreReverseAskQuery.interpret("yesterday").interval)
        try fixture.meeting(id: 9001, start: day.start.addingTimeInterval(3600), text: nil)
        do {
            _ = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: EchoProvider())
                .answer(question: "What happened yesterday?", apiKey: "synthetic")
            XCTFail("Missing transcript must not look like complete coverage")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without an available transcript"))
        }
    }

    func testLatestMeetingUsesChronologyWithoutLiteralKeywordMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.meeting(id: 9001, start: Date().addingTimeInterval(-3650), text: "Old project was cancelled.")
        try fixture.meeting(id: 9000, start: Date().addingTimeInterval(-3670), text: nil)
        try fixture.meeting(id: 9002, start: Date().addingTimeInterval(-3600), text: "Adopt tenant partitioning and ask Ada to own it.")
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: EchoProvider())
            .answer(question: "What decisions did we make in our last meeting?", apiKey: "synthetic")
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertTrue(answer.text.contains("tenant partitioning"))
        XCTAssertFalse(answer.text.contains("cancelled"))
        XCTAssertFalse(answer.text.contains("without an available transcript"))
    }

    func testQualifiedLastMeetingDoesNotChooseUnrelatedNewestMeeting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.meeting(id: 9001, start: Date().addingTimeInterval(-7200), text: "Acme approved tenant partitioning.")
        try fixture.meeting(id: 9002, start: Date().addingTimeInterval(-3600), text: "Unrelated gardening discussion.")
        let answer = try await LibreReverseAskEngine(configuration: fixture.configuration, provider: PlanningProvider(plans: [#"{"operations":[]}"#]))
            .answer(question: "What happened in the last meeting with Acme?", apiKey: "synthetic")
        XCTAssertTrue(answer.text.contains("Acme approved"))
        XCTAssertFalse(answer.text.contains("gardening"))
    }

    func testCancellationPreventsPlanningProviderCall() async throws {
        let provider = PlanningProvider(plans: [])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await LibreReverseAskRetrievalPlanner.plan(question: "Find capacity", candidates: [], completed: [], provider: provider, apiKey: "synthetic")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let calls = await provider.planningCalls
        XCTAssertEqual(calls, 0)
    }

    func testTranscriptPassageDeepLinkUsesPersistedWordTiming() throws {
        let text = String(repeating: "Introduction ", count: 100) + "Capacity invariant was approved."
        let offset = try XCTUnwrap(text.range(of: "Capacity")).lowerBound.utf16Offset(in: text)
        let start = Date(timeIntervalSince1970: 1_000)
        let transcript = LibreReverseMeetingTranscript(segmentID: 1, title: "Review", text: text,
            startDate: start, endDate: start.addingTimeInterval(600), words: [
                .init(id: 1, speechSource: "me", text: "Introduction", startSeconds: 0, durationSeconds: 1, fullTextUTF16Offset: 0),
                .init(id: 2, speechSource: "others", text: "Introduction", startSeconds: 290, durationSeconds: 1, fullTextUTF16Offset: offset - 110),
                .init(id: 3, speechSource: "others", text: "Capacity", startSeconds: 300, durationSeconds: 1, fullTextUTF16Offset: offset)
            ])
        let instant = try XCTUnwrap(LibreReverseAskPassage.instant(transcript: transcript, terms: ["capacity"]))
        XCTAssertEqual(instant.timeIntervalSince(start), 290, accuracy: 0.01)
        let citation = LibreReverseAskCitation(instant: start, title: "Review", excerpt: "Capacity", source: "Transcript", passageInstant: instant)
        XCTAssertEqual(citation.deepLink, MomentDeepLink.url(for: instant))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; items.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
private struct SmallConversationProvider: LibreReverseAskAnswerProvider, LibreReverseAskContextBudgetProvider {
    var allowsFullTranscriptEvidence: Bool { true }
    func contextBudget() async throws -> LibreReverseAskContextBudget {
        .init(contextTokens: 4096, outputTokens: 700)
    }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        let budget = try await contextBudget()
        let evidence = citations.map(\.providerText).joined(separator: "\n")
        guard question.utf8.count + evidence.utf8.count <= budget.inputTokens else {
            throw LibreReverseAskError.provider("Synthetic model context exceeded")
        }
        XCTAssertTrue(question.contains("Earlier answer"))
        return evidence
    }
}
private actor ConversationProvider: LibreReverseAskAnswerProvider, LibreReverseAskContextBudgetProvider {
    nonisolated var allowsFullTranscriptEvidence: Bool { true }
    var lastQuestion = ""
    func contextBudget() async throws -> LibreReverseAskContextBudget {
        .init(contextTokens: 131_072, outputTokens: 4_096)
    }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        lastQuestion = question
        return citations.map(\.providerText).joined(separator: "\n")
    }
}
private actor PlanningProvider: LibreReverseAskRetrievalPlanningProvider {
    nonisolated var allowsFullTranscriptEvidence: Bool { true }
    var planningCalls = 0
    let plans: [String]
    init(plans: [String]) { self.plans = plans }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        if question.hasPrefix("Select additional LOCAL retrieval") {
            let index = planningCalls; planningCalls += 1
            return index < plans.count ? plans[index] : #"{"operations":[]}"#
        }
        return citations.map(\.providerText).joined(separator: "\n")
    }
}
private struct EchoProvider: LibreReverseAskAnswerProvider {
    nonisolated var allowsFullTranscriptEvidence: Bool { true }
    func answer(question: String, citations: [LibreReverseAskCitation], apiKey: String) async throws -> String {
        citations.map(\.providerText).joined(separator: "\n")
    }
}
private struct Fixture {
    let root: URL
    let configuration: LibreReverseLibraryConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        configuration = .init(databaseURL: root.appendingPathComponent("library.sqlite3"), keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(configuration)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func screen(_ text: String, at date: Date) throws {
        let frame = try LibreReverseLibraryStore.admitFrame(createdAt: date, imageFileName: UUID().uuidString + ".png", context: .init(bundleID: "test.editor", windowName: "Notes"), configuration: configuration)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frame.id, document: .init(text: text, otherText: "", nodes: []), configuration: configuration)
    }
    func meeting(id: Int, start: Date, text: String?) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close(db) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(db, $0.baseAddress, Int32(key.count)) }, SQLITE_OK)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        var sql = "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(\(id),'test.meeting','\(formatter.string(from: start))','\(formatter.string(from: start.addingTimeInterval(600)))','Review',1);"
        if let text {
            sql += "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(\(id),'\(text)','','Review'); INSERT INTO search(rowid,text,otherText) VALUES(\(id),'\(text)',''); INSERT INTO searchOffsets(rowid,text,otherText) VALUES(\(id),'\(text)',''); INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(\(id),\(id),NULL);"
        }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
#endif
