#if os(macOS)
import Foundation

enum LibreReverseOpenAICompleteResponse {
    static func decode(_ data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LibreReverseAskError.invalidResponse
        }
        guard object["status"] as? String == "completed" else {
            throw LibreReverseAskError.provider("OpenAI did not finish this answer. Narrow the question or try again; partial output was not shown.")
        }
        if let error = object["error"], !(error is NSNull) { throw LibreReverseAskError.invalidResponse }
        guard let output = object["output"] as? [[String: Any]] else { throw LibreReverseAskError.invalidResponse }
        var parts: [String] = []
        for item in output where item["type"] as? String == "message" {
            if let status = item["status"] as? String, status != "completed" {
                throw LibreReverseAskError.invalidResponse
            }
            guard let content = item["content"] as? [[String: Any]] else { throw LibreReverseAskError.invalidResponse }
            for part in content {
                if part["type"] as? String == "refusal" {
                    throw LibreReverseAskError.provider("The provider declined to answer this question.")
                }
                if part["type"] as? String == "output_text", let text = part["text"] as? String { parts.append(text) }
            }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibreReverseAskError.invalidResponse }
        return text
    }
}
#endif
