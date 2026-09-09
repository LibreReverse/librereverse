import AppKit

/// Resolution-independent downward marker for the timeline playhead.
enum LibreReversePlayheadArrowAsset {
    static let pointSize = NSSize(width: 9, height: 7)

    static func draw(in rect: NSRect, color: NSColor) {
        guard let graphics = NSGraphicsContext.current?.cgContext else { return }
        graphics.saveGState()
        defer { graphics.restoreGState() }
        graphics.setFillColor(color.cgColor)
        graphics.beginPath()
        graphics.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        graphics.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        graphics.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        graphics.closePath()
        graphics.fillPath()
    }
}
