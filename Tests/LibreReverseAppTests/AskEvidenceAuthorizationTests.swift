import XCTest
@testable import LibreReverseApp

final class AskEvidenceAuthorizationTests: XCTestCase {
    func testRouteEditsInvalidateGrantAndOldProfilesDecodeWithoutGrant() throws {
        let data = Data(#"{"id":"saved","name":"Saved","provider":"OpenRouter","model":"model","preferredProviders":[],"allowFallbacks":true}"#.utf8)
        let old = try JSONDecoder().decode(LibreReverseAIProfile.self, from: data)
        XCTAssertFalse(old.hasFullTranscriptAuthorization)
        var granted = LibreReverseAIProfile.deepSeek
        granted.fullTranscriptAuthorization = granted.fullTranscriptRouteFingerprint
        XCTAssertTrue(granted.hasFullTranscriptAuthorization)
        var edited = granted; edited.model += "-changed"
        XCTAssertFalse(edited.hasFullTranscriptAuthorization)
        edited = granted; edited.provider = .openAI
        XCTAssertFalse(edited.hasFullTranscriptAuthorization)
        edited = granted; edited.preferredProviders = ["provider"]
        XCTAssertFalse(edited.hasFullTranscriptAuthorization)
        edited = granted; edited.allowFallbacks.toggle()
        XCTAssertFalse(edited.hasFullTranscriptAuthorization)
    }

    func testOpenRouterNeverSendsFullEvidenceWithoutExactRouteGrant() throws {
        let citation = LibreReverseAskCitation(instant: Date(timeIntervalSince1970: 0), title: "Synthetic",
            excerpt: "PREVIEW", source: "Transcript", evidence: "FULLTAILMARKER")
        func body(_ profile: LibreReverseAIProfile) throws -> String {
            let request = try LibreReverseOpenRouterProvider(profile: profile).request(question: "Question", citations: [citation], apiKey: "synthetic")
            return String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        }
        var profile = LibreReverseAIProfile.deepSeek
        XCTAssertFalse(try body(profile).contains("FULLTAILMARKER"))
        XCTAssertTrue(try body(profile).contains("PREVIEW"))
        profile.fullTranscriptAuthorization = profile.fullTranscriptRouteFingerprint
        XCTAssertTrue(try body(profile).contains("FULLTAILMARKER"))
        profile.model += "-different"
        XCTAssertFalse(try body(profile).contains("FULLTAILMARKER"))
    }
}
