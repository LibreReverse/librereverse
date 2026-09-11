#if os(macOS)
import Foundation

/// Keeps only the visible answer and counters after each event is decoded.
/// Reasoning payloads exist only transiently in the bounded current JSON event.
struct LibreReverseOpenRouterEventStream {
    enum Result: Equatable { case complete(String), lengthLimited }
    private var line = Data()
    private var event = Data()
    private var bytesRead = 0
    private var visibleText = ""
    private var visibleBytes = 0
    private var finishReason: String?
    private(set) var processingUpdates = 0
    private(set) var visibleCharacters = 0
    private(set) var isDone = false
    private let byteLimit: Int
    init(byteLimit: Int = 8_000_000) { self.byteLimit = byteLimit }

    var progressMessage: String {
        if visibleCharacters > 0 { return "AI is writing the answer · \(visibleCharacters) characters received" }
        return "AI is processing · \(processingUpdates) updates received"
    }

    mutating func consume(_ byte: UInt8) throws {
        guard !isDone else { return }
        bytesRead += 1
        guard bytesRead <= byteLimit else { throw failure("The AI response exceeded the streaming size limit. Narrow the question.") }
        if byte == 10 { try consumeLine() }
        else {
            line.append(byte)
            guard line.count <= 262_144 else { throw failure("The AI returned an oversized stream event.") }
        }
    }

    private mutating func consumeLine() throws {
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw LibreReverseAskError.invalidResponse }
        line.removeAll(keepingCapacity: false)
        if text.isEmpty { try dispatchEvent(); return }
        if text.hasPrefix(":") { return } // Standard SSE keepalive comment.
        guard text.hasPrefix("data:") else { return }
        var data = text.dropFirst(5)
        if data.first == " " { data = data.dropFirst() }
        if !event.isEmpty { event.append(10) }
        event.append(contentsOf: data.utf8)
        guard event.count <= 524_288 else { throw failure("The AI returned an oversized stream event.") }
    }

    private mutating func dispatchEvent() throws {
        guard !event.isEmpty else { return }
        let payload = event
        event = Data()
        if String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            isDone = true; return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { throw LibreReverseAskError.invalidResponse }
        if let error = json["error"], !(error is NSNull) { throw failure("The AI provider reported a streaming error. Please try again.") }
        guard let choices = json["choices"] as? [[String: Any]] else { throw LibreReverseAskError.invalidResponse }
        guard let choice = choices.first else { return } // Optional usage-only event.
        if let index = choice["index"] as? Int, index != 0 { throw LibreReverseAskError.invalidResponse }
        if let error = choice["error"], !(error is NSNull) { throw failure("The AI provider reported a streaming error. Please try again.") }
        if let delta = choice["delta"] as? [String: Any] {
            if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
                throw failure("The AI provider declined to answer this question.")
            }
            let hasReasoning = ["reasoning", "reasoning_content", "reasoning_details"].contains { key in
                if let text = delta[key] as? String { return !text.isEmpty }
                if let values = delta[key] as? [Any] { return !values.isEmpty }
                return false
            }
            if hasReasoning { processingUpdates += 1 }
            if let text = delta["content"] as? String, !text.isEmpty {
                guard finishReason == nil else { throw LibreReverseAskError.invalidResponse }
                visibleBytes += text.utf8.count
                guard visibleBytes <= 1_000_000 else { throw failure("The AI answer exceeded the response size limit.") }
                visibleText += text
                visibleCharacters += text.count
            }
        }
        if let reason = choice["finish_reason"] as? String {
            if let prior = finishReason {
                // OpenRouter's final accounting frame repeats the terminal
                // reason with empty content. It is not a second completion.
                let delta = choice["delta"] as? [String: Any]
                guard json["usage"] is [String: Any], prior == reason,
                    (delta?["content"] as? String ?? "").isEmpty else {
                    throw LibreReverseAskError.invalidResponse
                }
                return
            }
            switch reason {
            case "stop", "length": finishReason = reason
            case "content_filter": throw failure("The provider filtered this response and did not return a complete answer.")
            case "error": throw failure("The AI provider reported a streaming error. Please try again.")
            default: throw LibreReverseAskError.invalidResponse
            }
        }
    }

    mutating func finish() throws -> Result {
        if !line.isEmpty { try consumeLine() }
        try dispatchEvent()
        if finishReason == "length" { return .lengthLimited }
        guard finishReason == "stop" else { throw failure("The AI connection ended before its answer was complete. Please try again.") }
        let text = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibreReverseAskError.invalidResponse }
        return .complete(text)
    }

    private func failure(_ message: String) -> LibreReverseAskError { .provider(message) }
}
#endif
