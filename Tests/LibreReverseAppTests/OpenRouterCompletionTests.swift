import Foundation
import XCTest
@testable import LibreReverseApp

private final class CompletionFixture: @unchecked Sendable {
    let lock = NSLock()
    var responses: [Data]
    var tokenLimits: [Int] = []
    private var requestedStreams: [Bool] = []
    private var metadataCarriedPrivateInput = false
    let statusCode: Int
    let holdStreamOpen: Bool
    private let transportStopped: (@Sendable () -> Void)?
    private var stopCount = 0
    private let deferFirstResponse: Bool
    private let firstResponseArrived: (@Sendable () -> Void)?
    private var deliveryCount = 0
    private var deferredDelivery: (@Sendable () -> Void)?
    init(_ responses: [Data], statusCode: Int = 200, deferFirstResponse: Bool = false, firstResponseArrived: (@Sendable () -> Void)? = nil, holdStreamOpen: Bool = false, transportStopped: (@Sendable () -> Void)? = nil) {
        self.responses = responses; self.statusCode = statusCode; self.deferFirstResponse = deferFirstResponse
        self.firstResponseArrived = firstResponseArrived
        self.holdStreamOpen = holdStreamOpen; self.transportStopped = transportStopped
    }
    func recordTransportStop() {
        lock.lock(); stopCount += 1; let first = stopCount == 1; lock.unlock()
        if first { transportStopped?() }
    }
    var transportStopCount: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    func deliver(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldDefer = deferFirstResponse && deliveryCount == 0
        deliveryCount += 1
        if shouldDefer { deferredDelivery = action }
        lock.unlock()
        if shouldDefer { firstResponseArrived?() } else { action() }
    }
    func discardFirstResponse() { lock.lock(); deferredDelivery = nil; lock.unlock() }
    func releaseFirstResponse() {
        lock.lock(); let action = deferredDelivery; deferredDelivery = nil; lock.unlock()
        action?()
    }
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
        if request.httpMethod == "GET", !body.isEmpty || request.value(forHTTPHeaderField: "Authorization") != nil { metadataCarriedPrivateInput = true }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        tokenLimits.append(json?["max_tokens"] as? Int ?? -1)
        requestedStreams.append(json?["stream"] as? Bool ?? false)
        return responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
    }
    var metadataWasPublic: Bool { lock.lock(); defer { lock.unlock() }; return !metadataCarriedPrivateInput }
    var streamFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return requestedStreams }
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
        let data = fixture.next(request)
        fixture.deliver { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.statusCode, httpVersion: nil, headerFields: ["Content-Type": fixture.streamFlags.last == true ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if !fixture.holdStreamOpen { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {
        if let key = request.value(forHTTPHeaderField: "X-Fixture-ID") {
            Self.registry.get(key)?.recordTransportStop()
        }
    }
}

private final class StreamProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
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
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session, modelMetadata: .init(fixedBudget: .init(contextTokens: 128000, outputTokens: 16384)))
        let result: Result<String, Error>
        do { result = .success(try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic")) }
        catch { result = .failure(error) }
        verify(result, fixture.limits)
    }
    func testReasoningPolicyUsesOnlySupportedCapabilitiesAndPreservesRoute() throws {
        func policy(_ reasoning: String) -> LibreReverseOpenRouterReasoningPolicy? {
            LibreReverseOpenRouterReasoningPolicy.decode(Data(("{\"data\":{\"reasoning\":" + reasoning + "}}").utf8))
        }
        let low = policy(#"{"mandatory":false,"default_enabled":true,"supported_efforts":["max","high","low"],"default_effort":"high"}"#)
        XCTAssertEqual(low, .effort("low"))
        XCTAssertNil(policy(#"{"mandatory":true,"supported_efforts":["high"]}"#))
        XCTAssertNil(policy(#"{}"#))
        XCTAssertNil(LibreReverseOpenRouterReasoningPolicy.decode(Data("{}".utf8)))
        XCTAssertNil(policy(#"{"supports_max_tokens":true}"#))
        XCTAssertNil(policy(#"{"supported_efforts":null}"#))
        var profile = LibreReverseAIProfile.deepSeek
        profile.model = "deepseek/deepseek-v4.1-flash"
        profile.preferredProviders = ["Synthetic"]
        profile.allowFallbacks = false
        let provider = LibreReverseOpenRouterProvider(profile: profile)
        for stream in [false, true] {
            for limit in [8192, 16384] {
                let request = try provider.request(question: "Synthetic", citations: [], apiKey: "synthetic", maxTokens: limit, stream: stream, reasoningPolicy: low)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
                XCTAssertEqual(body["max_tokens"] as? Int, limit)
                XCTAssertEqual(body["model"] as? String, profile.model)
                XCTAssertEqual((body["provider"] as? [String: Any])?["order"] as? [String], ["Synthetic"])
                XCTAssertEqual((body["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
            }
        }
        let request = try provider.request(question: "Synthetic", citations: [], apiKey: "synthetic")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["reasoning"])
    }

    func testReasoningMetadataIsPublicCachedAndFailureOmitsOverride() async throws {
        let profile = LibreReverseAIProfile.deepSeek
        let metadata = try JSONSerialization.data(withJSONObject: ["data": ["id": profile.model, "reasoning": ["supported_efforts": ["high", "low"]]]])
        let fixture = CompletionFixture([metadata, Data("{}".utf8)])
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = LibreReverseOpenRouterModelMetadata(session: session)
        let now = Date(timeIntervalSince1970: 1000)
        let first = try await cache.reasoningPolicy(for: profile, now: now)
        let cached = try await cache.reasoningPolicy(for: profile, now: now.addingTimeInterval(1))
        XCTAssertEqual(first, .effort("low")); XCTAssertEqual(cached, first)
        XCTAssertEqual(fixture.limits.count, 1)
        let failed = try await cache.reasoningPolicy(for: profile, now: now.addingTimeInterval(3601))
        XCTAssertNil(failed)
        XCTAssertTrue(fixture.metadataWasPublic)
        XCTAssertEqual(fixture.limits.count, 2)
    }

    func testPublicMetadataCachesSuccessAndUsesFallbackWithoutCredentials() async throws {
        let metadata = Data(#"{"data":{"endpoints":[{"provider_name":"Synthetic","context_length":128000,"max_completion_tokens":16384}]}}"#.utf8)
        let fixture = CompletionFixture([metadata, Data("{}".utf8)])
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = LibreReverseOpenRouterModelMetadata(session: session)
        let now = Date(timeIntervalSince1970: 1000)
        let first = try await cache.budget(for: .deepSeek, now: now)
        let cached = try await cache.budget(for: .deepSeek, now: now.addingTimeInterval(10))
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first.contextTokens, 128000)
        XCTAssertEqual(fixture.limits.count, 1)
        let fallback = try await cache.budget(for: .deepSeek, now: now.addingTimeInterval(3601))
        XCTAssertEqual(fallback, .fallback)
        _ = try await cache.budget(for: .deepSeek, now: now.addingTimeInterval(3610))
        XCTAssertEqual(fixture.limits.count, 2)
        XCTAssertTrue(fixture.metadataWasPublic)
    }

    func testUnmatchedRouteDoesNotPoisonOtherProfilesModelMetadata() async throws {
        let data = Data(#"{"data":{"endpoints":[{"provider_name":"Available","context_length":128000,"max_completion_tokens":16384}]}}"#.utf8)
        let fixture = CompletionFixture([data])
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cache = LibreReverseOpenRouterModelMetadata(session: session)
        var unmatched = LibreReverseAIProfile.deepSeek
        unmatched.preferredProviders = ["Missing"]; unmatched.allowFallbacks = false
        let first = try await cache.budget(for: unmatched)
        let other = try await cache.budget(for: .deepSeek)
        XCTAssertEqual(first, .fallback)
        XCTAssertEqual(other.contextTokens, 128000)
        XCTAssertEqual(fixture.limits.count, 1)
    }

    func testLateConcurrentFailureCannotOverwriteSuccessfulMetadata() async throws {
        let arrived = expectation(description: "First response held")
        let data = Data(#"{"data":{"endpoints":[{"provider_name":"Available","context_length":128000,"max_completion_tokens":16384}]}}"#.utf8)
        let fixture = CompletionFixture([Data("{}".utf8), data], deferFirstResponse: true, firstResponseArrived: { arrived.fulfill() })
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cache = LibreReverseOpenRouterModelMetadata(session: session)
        let first = Task { try await cache.budget(for: .deepSeek) }
        await fulfillment(of: [arrived], timeout: 2)
        let successful = try await cache.budget(for: .deepSeek)
        fixture.releaseFirstResponse()
        let late = try await first.value
        let cached = try await cache.budget(for: .deepSeek)
        XCTAssertEqual(successful.contextTokens, 128000)
        XCTAssertEqual(late, successful)
        XCTAssertEqual(cached, successful)
        XCTAssertEqual(fixture.limits.count, 2)
    }

    func testStreamingOverloadRetriesWithoutLeakingReasoningOrPartialAnswer() async throws {
        func stream(_ content: String, finish: String) -> Data {
            Data(("data: {\"choices\":[{\"delta\":{\"reasoning\":\"RAW_PRIVATE_REASONING\"},\"finish_reason\":null}]}\n\n"
                + "data: {\"choices\":[{\"delta\":{\"content\":\"" + content + "\"},\"finish_reason\":\"" + finish + "\"}]}\n\ndata: [DONE]\n\n").utf8)
        }
        let fixture = CompletionFixture([stream("Partial", finish: "length"), stream("Complete answer", finish: "stop")])
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session,
            modelMetadata: .init(fixedBudget: .init(contextTokens: 128000, outputTokens: 16384)))
        let progress = StreamProgressRecorder()
        let answer = try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic", onProgress: { progress.record($0) })
        XCTAssertEqual(answer, "Complete answer")
        XCTAssertEqual(fixture.limits, [8192, 16384])
        XCTAssertEqual(fixture.streamFlags, [true, true])
        XCTAssertTrue(progress.values.contains { $0.hasPrefix("progress.update:") })
        XCTAssertTrue(progress.values.contains { $0.contains("retrying once") })
        XCTAssertFalse(progress.values.joined().contains("RAW_PRIVATE_REASONING"))
        XCTAssertFalse(progress.values.joined().contains("Partial"))
    }

    func testStreamingCancellationEndsOwnedRequest() async throws {
        let arrived = expectation(description: "Streaming request admitted")
        let fixture = CompletionFixture([Data()], deferFirstResponse: true, firstResponseArrived: { arrived.fulfill() })
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { fixture.discardFirstResponse(); CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session,
            modelMetadata: .init(fixedBudget: .init(contextTokens: 128000, outputTokens: 16384)))
        let task = Task { try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic", onProgress: { _ in }) }
        await fulfillment(of: [arrived], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(type(of: error))") }
        XCTAssertEqual(fixture.limits.count, 1)
    }

    func testMidStreamCancellationStopsTransportAfterProcessingProgress() async throws {
        let processing = expectation(description: "Parser reported a processing update")
        let stopped = expectation(description: "Native URLProtocol transport stopped")
        let data = Data("data: {\"choices\":[{\"delta\":{\"reasoning\":\"PRIVATE_REASONING_SENTINEL\"},\"finish_reason\":null}]}\n\n".utf8)
        let fixture = CompletionFixture([data], holdStreamOpen: true, transportStopped: { stopped.fulfill() })
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session,
            modelMetadata: .init(fixedBudget: .init(contextTokens: 128000, outputTokens: 16384)))
        let progress = StreamProgressRecorder()
        let task = Task {
            try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic", onProgress: {
                progress.record($0)
                if $0.hasPrefix("progress.update:") { processing.fulfill() }
            })
        }
        await fulfillment(of: [processing], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("A canceled partial stream returned a final answer") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(type(of: error))") }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertGreaterThan(fixture.transportStopCount, 0)
        XCTAssertEqual(fixture.limits.count, 1)
        XCTAssertTrue(progress.values.contains { $0.contains("1 updates received") })
        XCTAssertFalse(progress.values.joined().contains("PRIVATE_REASONING_SENTINEL"))
    }

    func testStreamingAuthenticationErrorPointsToAISettings() async throws {
        let fixture = CompletionFixture([Data()], statusCode: 401)
        let key = CompletionURLProtocol.registry.insert(fixture)
        defer { CompletionURLProtocol.registry.remove(key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletionURLProtocol.self]; config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let provider = LibreReverseOpenRouterProvider(profile: .deepSeek, session: session,
            modelMetadata: .init(fixedBudget: .init(contextTokens: 128000, outputTokens: 16384)))
        do {
            _ = try await provider.answer(question: "Synthetic", citations: [], apiKey: "synthetic", onProgress: { _ in })
            XCTFail("Expected authentication error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Settings → AI")) }
        XCTAssertEqual(fixture.limits.count, 1)
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
