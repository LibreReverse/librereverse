import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AskMarkdownTests: XCTestCase {
    func testQuestionListKeepsNumbersCitationsAndLineBreaks() {
        let result = LibreReverseAskMarkdown.render("## Interview questions\n\n1. **Why this role?** [1]\n2. What came next? [2]")
        XCTAssertEqual(result.string, "Interview questions\n\n1. Why this role? [1]\n2. What came next? [2]")
        let range = (result.string as NSString).range(of: "Why this role?")
        let font = result.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(NSFontManager.shared.weight(of: font!), NSFontManager.shared.weight(of: NSFont.systemFont(ofSize: 15)))
    }

    func testCodeKeepsLiteralFormattingAndGeneratedLinksAreNotActions() {
        let result = LibreReverseAskMarkdown.render("- Read `some_value`\n```swift\nlet **literal** = 1\n```\n[Link](https://example.com)")
        XCTAssertTrue(result.string.contains("• Read some_value"))
        XCTAssertTrue(result.string.contains("let **literal** = 1"))
        XCTAssertTrue(result.string.hasSuffix("Link"))
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            XCTAssertNil(value)
        }
    }
}
