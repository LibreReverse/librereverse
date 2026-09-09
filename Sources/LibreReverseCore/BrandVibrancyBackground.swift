import Foundation

/// Geometry, opacity, and AppKit material choices for the media surface.
public enum BrandVibrancyBackgroundContract {
    public enum Style: UInt8, CaseIterable, Sendable {
        case light = 0
        case medium = 1
        case heavy = 2
    }

    public enum VibrancyEffectStyle: UInt8, CaseIterable, Sendable {
        case behindWindow = 0
        case withinWindow = 1
        case contentBackground = 2
    }

    public struct VisualEffectMapping: Equatable, Sendable {
        public let blendingModeRawValue: Int
        public let materialRawValue: Int
        public let isAlwaysActive: Bool
        public let isEmphasized: Bool

        // A public struct only gets an internal memberwise initializer, so
        // callers outside the module cannot construct expected values.
        public init(
            blendingModeRawValue: Int,
            materialRawValue: Int,
            isAlwaysActive: Bool,
            isEmphasized: Bool
        ) {
            self.blendingModeRawValue = blendingModeRawValue
            self.materialRawValue = materialRawValue
            self.isAlwaysActive = isAlwaysActive
            self.isEmphasized = isEmphasized
        }
    }

    public static let frameDetailCornerRadius = 10.0
    public static let frameDetailCallerOpacity = 0.85
    public static let strokeWidth = 1.0
    // Float color components widened to Double without intermediate rounding.
    public static let brandBlackRed = 0.20000000298023224
    public static let brandBlackGreen = 0.20000000298023224
    public static let brandBlackBlue = 0.20000000298023224

    /// Background opacity for each visual emphasis.
    public static func opacity(for style: Style) -> Double {
        switch style {
        case .light: 0.2
        case .medium: 0.5
        case .heavy: 0.8
        }
    }

    /// AppKit blending and material values for each vibrancy placement.
    public static func visualEffectMapping(
        for style: VibrancyEffectStyle
    ) -> VisualEffectMapping {
        switch style {
        case .behindWindow:
            VisualEffectMapping(
                blendingModeRawValue: 0,
                materialRawValue: 15,
                isAlwaysActive: true,
                isEmphasized: false
            )
        case .withinWindow:
            VisualEffectMapping(
                blendingModeRawValue: 1,
                materialRawValue: 15,
                isAlwaysActive: true,
                isEmphasized: false
            )
        case .contentBackground:
            VisualEffectMapping(
                blendingModeRawValue: 1,
                materialRawValue: 18,
                isAlwaysActive: true,
                isEmphasized: false
            )
        }
    }
}
