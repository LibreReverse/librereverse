#if os(macOS)
import Foundation

/// Search-preview crop geometry: start 50 points above and left of the OCR
/// match, then scale the fixed preview size into source-image pixels.
public enum SearchCropRequest {
    public static let topInset: CGFloat = 50
    public static let leadingInset: CGFloat = 50
    public static let defaultBackingScale: CGFloat = 2

    public static func sourceRectangle(
        match: CGRect,
        targetSize: CGSize,
        backingScale: CGFloat = defaultBackingScale
    ) -> CGRect {
        precondition(targetSize.width > 0 && targetSize.height > 0 && backingScale > 0)
        return CGRect(
            x: match.minX - leadingInset * backingScale,
            y: match.minY - topInset * backingScale,
            width: targetSize.width * backingScale,
            height: targetSize.height * backingScale
        )
    }
}
#endif
