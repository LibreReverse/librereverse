#if os(macOS)
import Foundation

enum LibreReverseAskCitationValidation {
    struct Reference: Equatable { let range: NSRange; let sourceIDs: [Int] }
    static func references(in text: String, sourceCount: Int) throws -> [Reference] {
        let regex = try NSRegularExpression(pattern: #"\[\s*[0-9]+(?:\s*[,;–—-]\s*[0-9]+)*\s*\]"#)
        return try regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let content = (text as NSString).substring(with: match.range).dropFirst().dropLast()
            let groups = content.split(whereSeparator: { $0 == "," || $0 == ";" })
            var ids: [Int] = []
            for group in groups {
                let numbers = group.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" }).map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard !numbers.isEmpty, numbers.count <= 2,
                    let first = numbers[0], first > 0, first <= sourceCount else { throw invalidCitation() }
                let last: Int
                if numbers.count == 2 {
                    guard let end = numbers[1], end >= first, end <= sourceCount else { throw invalidCitation() }
                    last = end
                } else { last = first }
                ids.append(contentsOf: first...last)
            }
            return Reference(range: match.range, sourceIDs: ids)
        }
    }
    static func validate(_ text: String, sourceCount: Int) throws {
        _ = try references(in: text, sourceCount: sourceCount)
    }
    static func removingReferences(from text: String) -> String {
        text.replacingOccurrences(of: #"\[\s*[0-9]+(?:\s*[,;–—-]\s*[0-9]+)*\s*\]"#, with: "", options: .regularExpression)
    }
    private static func invalidCitation() -> LibreReverseAskError {
        .provider("The model cited a source that was not supplied. Please try again or narrow the question.")
    }
}
#endif
