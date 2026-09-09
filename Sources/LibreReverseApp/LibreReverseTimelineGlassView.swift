#if os(macOS)
import AppKit

/// A native glass surface whose unoccupied areas leave input to the timeline.
@MainActor
final class LibreReverseTimelineGlassView: NSView {
    let contentView = NSView(frame: .zero)

    private let glassView = NSGlassEffectView(frame: .zero)
    private var reducesTransparency = false
    private let radius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous

        glassView.style = .regular
        glassView.tintColor = nil
        glassView.cornerRadius = radius
        glassView.autoresizingMask = [.width, .height]
        contentView.autoresizingMask = [.width, .height]
        addSubview(glassView)
        glassView.contentView = contentView

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        updateAccessibilityAppearance()
        layoutSurface()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func layout() {
        super.layout()
        layoutSurface()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFallbackColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0,
              bounds.contains(convert(point, from: superview)),
              let contentParent = contentView.superview else { return nil }

        // Do not ask the glass for a hit: its private effect views can become
        // the target in empty space. Native scroll and collection descendants
        // still perform their own hit testing, clipping and event arbitration.
        let contentPoint = contentParent.convert(point, from: superview)
        let hit = contentView.hitTest(contentPoint)
        return hit === contentView ? nil : hit
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        updateAccessibilityAppearance()
    }

    private func updateAccessibilityAppearance() {
        let shouldReduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if shouldReduce != reducesTransparency {
            reducesTransparency = shouldReduce
            if shouldReduce {
                glassView.contentView = nil
                addSubview(contentView)
                glassView.isHidden = true
            } else {
                contentView.removeFromSuperview()
                glassView.contentView = contentView
                glassView.isHidden = false
            }
            layoutSurface()
        }
        updateFallbackColor()
    }

    private func updateFallbackColor() {
        // The ordinary surface has no painted tint over the system glass.
        // Resolve the opaque accessibility fallback in this view's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = reducesTransparency
                ? NSColor.windowBackgroundColor.cgColor
                : nil
        }
    }

    private func layoutSurface() {
        glassView.frame = bounds
        if reducesTransparency {
            contentView.frame = bounds
        } else {
            // NSGlassEffectView owns the content's placement and internal
            // hierarchy. Size its one supported content view, never insert
            // foreground views alongside the glass's private subviews.
            contentView.setFrameSize(bounds.size)
        }
    }
}
#endif
