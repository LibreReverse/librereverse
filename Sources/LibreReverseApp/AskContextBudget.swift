#if os(macOS)
import Foundation

struct LibreReverseAskContextBudget: Equatable, Sendable {
    let contextTokens: Int
    let outputTokens: Int
    var inputTokens: Int { max(0, contextTokens - outputTokens - 1_024) }
    static let fallback = Self(contextTokens: 8_192, outputTokens: 2_048)
    // UTF-8 bytes conservatively bound byte-level tokenization without assuming
    // that non-English text has the English four-characters-per-token ratio.
    static func estimatedTokens(_ text: String) -> Int { text.utf8.count }
    func evidenceCapacity(question: String) -> Int {
        max(0, inputTokens - Self.estimatedTokens(question))
    }
}

protocol LibreReverseAskContextBudgetProvider: Sendable {
    func contextBudget() async throws -> LibreReverseAskContextBudget
}

enum LibreReverseOpenRouterReasoningPolicy: Equatable, Sendable {
    case effort(String)

    func parameters(outputTokens: Int) -> [String: Any] {
        switch self {
        case .effort(let value): return ["effort": value]
        }
    }

    static func decode(_ data: Data) -> Self? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let model = json["data"] as? [String: Any],
            let reasoning = model["reasoning"] as? [String: Any] else { return nil }
        // Select only an explicitly supported low effort. Some models require
        // high reasoning; never invent an unsupported setting or disable it.
        if let efforts = reasoning["supported_efforts"] as? [String] {
            for effort in ["low", "minimal"] where efforts.contains(effort) { return .effort(effort) }
        }
        return nil
    }
}

actor LibreReverseOpenRouterModelMetadata {
    static let shared = LibreReverseOpenRouterModelMetadata()
    private struct Entry { let data: Data; let expires: Date }
    private var cache: [String: Entry] = [:]
    private var reasoningCache: [String: Entry] = [:]
    private let session: URLSession
    private let fixedBudget: LibreReverseAskContextBudget?
    init(session: URLSession = .shared, fixedBudget: LibreReverseAskContextBudget? = nil) {
        self.session = session; self.fixedBudget = fixedBudget
    }

    func budget(for profile: LibreReverseAIProfile, now: Date = Date()) async throws -> LibreReverseAskContextBudget {
        try Task.checkCancellation()
        if let fixedBudget { return fixedBudget }
        let model = profile.model
        if let entry = cache[model], entry.expires > now {
            return Self.decode(entry.data, profile: profile) ?? .fallback
        }
        if cache.count >= 64 { cache = cache.filter { $0.value.expires > now }; if cache.count >= 64 { cache.removeAll() } }
        // Public capacity metadata only. No API key, question or evidence is sent.
        let components = model.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return .fallback }
        var url = URL(string: "https://openrouter.ai/api/v1/models")!
        for component in components { url.appendPathComponent(String(component)) }
        url.appendPathComponent("endpoints")
        var request = URLRequest(url: url); request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                data.count <= 2_000_000, Self.isValidModelMetadata(data, profile: profile) else {
                return cacheFailure(model: model, profile: profile, now: now)
            }
            cache[model] = Entry(data: data, expires: now.addingTimeInterval(3_600))
            return Self.decode(data, profile: profile) ?? .fallback
        } catch {
            try Task.checkCancellation()
            return cacheFailure(model: model, profile: profile, now: now)
        }
    }

    func reasoningPolicy(for profile: LibreReverseAIProfile, now: Date = Date()) async throws -> LibreReverseOpenRouterReasoningPolicy? {
        try Task.checkCancellation()
        // Fixed budgets keep test/offline providers entirely offline.
        if fixedBudget != nil { return nil }
        let model = profile.model
        if let entry = reasoningCache[model], entry.expires > now {
            return LibreReverseOpenRouterReasoningPolicy.decode(entry.data)
        }
        let components = model.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        if reasoningCache.count >= 64 { reasoningCache = reasoningCache.filter { $0.value.expires > now }; if reasoningCache.count >= 64 { reasoningCache.removeAll() } }
        var url = URL(string: "https://openrouter.ai/api/v1/model")!
        for component in components { url.appendPathComponent(String(component)) }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        do {
            // Public model capabilities only; never attach credentials/evidence.
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            if (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let object = json["data"] as? [String: Any], object["id"] as? String == model {
                reasoningCache[model] = Entry(data: data, expires: now.addingTimeInterval(3_600))
                return LibreReverseOpenRouterReasoningPolicy.decode(data)
            }
        } catch { try Task.checkCancellation() }
        if let entry = reasoningCache[model], entry.expires > now, !entry.data.isEmpty {
            return LibreReverseOpenRouterReasoningPolicy.decode(entry.data)
        }
        reasoningCache[model] = Entry(data: Data(), expires: now.addingTimeInterval(300))
        return nil
    }

    private func cacheFailure(model: String, profile: LibreReverseAIProfile, now: Date) -> LibreReverseAskContextBudget {
        // Another request may have succeeded while this actor was awaiting I/O.
        // A late failure must not replace its still-current capacity metadata.
        if let entry = cache[model], entry.expires > now, !entry.data.isEmpty {
            return Self.decode(entry.data, profile: profile) ?? .fallback
        }
        cache[model] = Entry(data: Data(), expires: now.addingTimeInterval(300))
        return .fallback
    }

    private static func isValidModelMetadata(_ data: Data, profile: LibreReverseAIProfile) -> Bool {
        // Cache raw model metadata independently of this caller's route. A route
        // with no matching endpoint must not poison another profile's cache.
        var unfiltered = profile
        unfiltered.preferredProviders = []
        unfiltered.allowFallbacks = true
        return decode(data, profile: unfiltered) != nil
    }

    static func decode(_ data: Data, profile: LibreReverseAIProfile) -> LibreReverseAskContextBudget? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let model = json["data"] as? [String: Any], let endpoints = model["endpoints"] as? [[String: Any]], !endpoints.isEmpty else { return nil }
        let selected = endpoints.filter { endpoint in
            profile.allowFallbacks || profile.preferredProviders.isEmpty
                || profile.preferredProviders.contains { $0.caseInsensitiveCompare(endpoint["provider_name"] as? String ?? "") == .orderedSame }
        }
        guard !selected.isEmpty else { return nil }
        var contexts: [Int] = [], outputs: [Int] = []
        for endpoint in selected {
            guard let context = endpoint["context_length"] as? Int, context >= 2_048, context <= 10_000_000 else { return nil }
            let prompt = endpoint["max_prompt_tokens"] as? Int ?? context
            let output = endpoint["max_completion_tokens"] as? Int ?? 2_048
            guard prompt > 0, output > 0 else { return nil }
            contexts.append(min(context, prompt)); outputs.append(output)
        }
        let context = contexts.min()!
        let output = min(16_384, outputs.min()!, context / 4)
        return .init(contextTokens: context, outputTokens: output)
    }
}
#endif
