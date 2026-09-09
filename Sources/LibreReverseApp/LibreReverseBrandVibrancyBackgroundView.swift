#if os(macOS)
import AppKit
import LibreReverseCore

/// AppKit rendering of the exact FrameDetail background stack.
///
/// Back to front, the shipping SwiftUI tree is an always-active visual-effect
/// view, the modifier's medium brand tint, and FrameDetail's caller-supplied
/// brand tint at 0.85 opacity. The owning player view applies the modifier's
/// continuous clip and one-point inset border to this background and all video
/// content together.
@MainActor
final class LibreReverseBrandVibrancyBackgroundView: NSView {
    private let visualEffectView = NSVisualEffectView(frame: .zero)
    private let modifierTintView = NSView(frame: .zero)
    private let callerTintView = NSView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // VisualEffectBackground.makeNSView initializes material 18 before the
        // first update. The final within-window mapping used by FrameDetail is
        // material 15, blending mode 1, always active, and not emphasized.
        visualEffectView.material = .contentBackground
        visualEffectView.material = .fullScreenUI
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.isEmphasized = false

        let brandBlack = NSColor(
            srgbRed: CGFloat(BrandVibrancyBackgroundContract.brandBlackRed),
            green: CGFloat(BrandVibrancyBackgroundContract.brandBlackGreen),
            blue: CGFloat(BrandVibrancyBackgroundContract.brandBlackBlue),
            alpha: 1
        )
        modifierTintView.wantsLayer = true
        modifierTintView.layer?.backgroundColor = brandBlack.withAlphaComponent(
            CGFloat(BrandVibrancyBackgroundContract.opacity(for: .medium))
        ).cgColor
        callerTintView.wantsLayer = true
        callerTintView.layer?.backgroundColor = brandBlack.withAlphaComponent(
            CGFloat(BrandVibrancyBackgroundContract.frameDetailCallerOpacity)
        ).cgColor

        addSubview(visualEffectView)
        addSubview(modifierTintView)
        addSubview(callerTintView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
        modifierTintView.frame = bounds
        callerTintView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
