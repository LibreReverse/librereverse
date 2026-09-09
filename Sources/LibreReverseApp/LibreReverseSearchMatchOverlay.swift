#if os(macOS)
import AppKit
import LibreReverseCore

/// Non-interactive query-match layer gated by the displayed frame identity.
/// Text selection lives in the independent Live Text interaction layer above it.
@MainActor
final class LibreReverseSearchMatchOverlay: NSView {
    private var nodes: [OCRNode] = []
    private var imageSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(nodes: [OCRNode], imageSize: CGSize) {
        guard !nodes.isEmpty, imageSize.width > 0, imageSize.height > 0 else {
            clear()
            return
        }
        self.nodes = nodes
        self.imageSize = imageSize
        isHidden = false
        needsDisplay = true
    }

    func clear() {
        nodes = []
        imageSize = .zero
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !nodes.isEmpty else { return }
        let borderWidth = FrameNodesVisualContract.borderWidth
        let radius = FrameNodesVisualContract.cornerRadius
        let rects = nodes.compactMap { node -> CGRect? in
            let projected = FrameNodesVisualContract.projectedRect(
                node: node,
                imageSize: imageSize,
                contentSize: bounds.size
            )
            guard projected.width > 0, projected.height > 0 else { return nil }
            return projected.insetBy(dx: -borderWidth, dy: -borderWidth)
        }
        guard !rects.isEmpty else { return }
        let mask = NSBezierPath(rect: bounds)
        for rect in rects {
            mask.appendRoundedRect(rect, xRadius: radius, yRadius: radius)
        }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(
            FrameNodesVisualContract.maskOpacity
        ).setFill()
        mask.fill()

        NSColor.systemYellow.withAlphaComponent(
            FrameNodesVisualContract.borderOpacity
        ).setStroke()
        for rect in rects {
            let border = NSBezierPath(
                roundedRect: rect,
                xRadius: radius,
                yRadius: radius
            )
            border.lineWidth = borderWidth
            border.stroke()
        }
    }
}
#endif
