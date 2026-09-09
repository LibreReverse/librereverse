#if os(macOS)
import CoreGraphics
import Foundation

/// Exact drawing constants and coordinate projection used by the app's
/// selected OCR-match highlight.
///
/// `HighlightMatchView.draw(_:)` builds an even-odd mask over the whole host,
/// cuts a rounded hole for each normalized top-left OCR rectangle, and then
/// strokes the hole. Keeping projection pure lets the app gate publication on
/// frame identity without coupling database coordinates to AppKit views.
public enum SearchMatchVisualContract {
    public static let maskOpacity: CGFloat = 0.30
    public static let borderOpacity: CGFloat = 0.85
    public static let borderWidth: CGFloat = 1.5
    public static let cornerRadius: CGFloat = 5

    /// `brand-yellow` from `RWCore_RWCoreUI.bundle`, read at runtime in the
    /// source Display P3 color space rather than after sRGB conversion.
    public static let displayP3Red: CGFloat = 1
    public static let displayP3Green: CGFloat = 0.902000010014
    public static let displayP3Blue: CGFloat = 0

    /// Projects normalized top-left OCR node coordinates into an AppKit
    /// bottom-left content surface containing an aspect-fit source image.
    public static func projectedRect(
        node: OCRNode,
        imageSize: CGSize,
        contentSize: CGSize
    ) -> CGRect {
        let imageRect = LiveTextContract.aspectFitRect(
            imageSize: imageSize,
            contentSize: contentSize
        )
        guard !imageRect.isEmpty else { return .zero }
        return CGRect(
            x: imageRect.minX + CGFloat(node.leftX) * imageRect.width,
            y: imageRect.minY
                + (1 - CGFloat(node.topY) - CGFloat(node.height)) * imageRect.height,
            width: CGFloat(node.width) * imageRect.width,
            height: CGFloat(node.height) * imageRect.height
        )
    }
}
#endif
