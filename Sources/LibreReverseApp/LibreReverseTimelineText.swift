#if os(macOS)
import AppKit
import CoreText

/// Main-thread, bounded text runs for the frequently redrawn transport labels.
/// Build native CoreText attributes one at a time. NSString's drawing bridge can
/// throw in TAttributes::ApplyFont while copying transient font dictionaries.
@MainActor
final class LibreReverseTimelineText {
    struct Run {
        let attributedString: CFAttributedString
        let line: CTLine
        let size: NSSize
        let descent: CGFloat

        func draw(at origin: NSPoint, in context: CGContext) {
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: origin.x, y: origin.y + descent)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private let font: CTFont
    private let color: CGColor
    private var runs: [String: Run] = [:]
    let capacity: Int
    var cachedRunCount: Int { runs.count }

    init(font: NSFont, color: NSColor, capacity: Int = 128) {
        self.font = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        self.color = color.cgColor
        self.capacity = max(1, capacity)
    }

    func run(for text: String) -> Run {
        if let cached = runs[text] { return cached }
        let mutable = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(mutable, CFRange(location: 0, length: 0), text as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(mutable))
        CFAttributedStringSetAttribute(mutable, range, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(mutable, range, kCTForegroundColorAttributeName, color)
        let immutable = CFAttributedStringCreateCopy(nil, mutable)!
        let line = CTLineCreateWithAttributedString(immutable)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let run = Run(attributedString: immutable, line: line,
            size: NSSize(width: width, height: ceil(ascent + descent + leading)), descent: descent)
        if runs.count >= capacity { runs.removeAll(keepingCapacity: true) }
        runs[text] = run
        return run
    }
}
#endif
