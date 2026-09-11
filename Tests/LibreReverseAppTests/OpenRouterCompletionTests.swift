import Foundation
import XCTest
@testable import LibreReverseApp

private final class CompletionFixture: @unchecked Sendable {
    let lock = NSLock()
    var responses: [Data]
    var tokenLimits: [Int] = []
    init(_ responses: [Data]) { self.responses = responses }
    func next(_ request: URLRequest) -> Data {
        lock.lock(); defer { lock.unlock() }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, body.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        tokenLimits.append(json?["max_tokens"] as? Int ?? -1)
        return responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
    }
    var limits: [Int] { lock.lock(); defer { lock.unlock() }; return tokenLimits }
}

private final class CompletionRegistry: @unchecked Sendable {
    let lock = NSLock()
    var fixtures: [String: CompletionFixture] = [:]
    func insert(_ fixture: CompletionFixture) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = UUID().uuidString; fixtures[key] = fixture; return key
    }
    func get(_ key: String) -> CompletionFixture? {
        lock.lock(); defer { lock.unlock() }; return fixtures[key]
    }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; fixtures[key] = nil }
}

private final class CompletionURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CompletionRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Fixture-ID"), let fixture = Self.registry.get(key) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.next(request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenRouterCompletionTests: XCTestCase {
    private func payload(_ reason: String, text: String = "Complete answer") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["content": text]]]])
    }
    private func run(_ responses: [Data], verify: (Result<String, Error>, [Int]) -> Void) async {
        let fixture = CompletionFixture(responses)
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session)
        let result: Result<String, Error>
        do { result = .success(try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic")) }
        catch { result = .failure(error) }
        verify(result, fixture.limits)
    }
    func testTruncatedResponseRetriesOnceWithLargerBudget() async {
        await run([payload("length", text: "Partial"), payload("stop")]) { result, limits in
            XCTAssertEqual(try? result.get(), "Complete answer")
            XCTAssertEqual(limits, [8192, 16384])
        }
    }
    func testRepeatedTruncationRejectsPartialAnswer() async {
        await run([payload("length"), payload("length")]) { result, limits in
            guard case .failure(let error) = result else { return XCTFail("Partial answer accepted") }
            XCTAssertTrue(error.localizedDescription.contains("output limit"))
            XCTAssertEqual(limits, [8192, 16384])
        }
    }
    func testOrdinarySuccessDoesNotRetry() async {
        await run([payload("stop")]) { result, limits in
            XCTAssertEqual(try? result.get(), "Complete answer")
            XCTAssertEqual(limits, [8192])
        }
    }
    func testMalformedFilteredAndErroredResponsesDoNotRetryOrSucceed() async {
        for data in [Data("not json".utf8), Data("{}".utf8), payload("content_filter"), payload("error"),
                     Data(#"{"error":{"message":"synthetic failure"}}"#.utf8)] {
            await run([data]) { result, limits in
                guard case .failure = result else { return XCTFail("Invalid response accepted") }
                XCTAssertEqual(limits, [8192])
            }
        }
    }
}
