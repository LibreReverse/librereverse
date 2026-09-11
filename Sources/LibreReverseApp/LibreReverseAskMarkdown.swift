#if os(macOS)
import AppKit
import Foundation

/// Renders presentation only; copying an entire answer keeps its original text.
@MainActor
enum LibreReverseAskMarkdown {
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var inCodeBlock = false
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            var line = rawLine
            var heading = false
            if !inCodeBlock {
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                    line = String(line.dropFirst(hashes + 1)); heading = true
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    line = "• " + line.dropFirst(2)
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = heading ? 8 : 3
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: heading ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if inCodeBlock {
                var attributes = base
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                result.append(NSAttributedString(string: line, attributes: attributes))
            } else if let parsed = try? AttributedString(markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    var attributes = base
                    let intent = run.inlinePresentationIntent ?? []
                    var font = NSFont.systemFont(ofSize: 15,
                        weight: heading || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
                    if intent.contains(.code) {
                        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                    } else if intent.contains(.emphasized) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    attributes[.font] = font
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    // Model-generated links are presentation text; navigable
                    // recorded sources are the independently validated buttons.
                    result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
                }
            } else {
                result.append(NSAttributedString(string: line, attributes: base))
            }
            if index + 1 < lines.count { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return result
    }
}
#endif
