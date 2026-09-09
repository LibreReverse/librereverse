#if os(macOS)
import CoreGraphics
import Foundation

/// Resolves matching text nodes for search highlighting.
/// Persisted node offsets share one global UTF-16 domain, while FTS4 reports
/// offsets relative to its primary and other-text columns independently.
public enum FrameTextNodeResolver {
    public static func matchingNodes(
        _ nodes: [OCRNode],
        offsetString: String,
        primaryText: String,
        otherText: String
    ) -> [OCRNode] {
        let offsets = SearchOffsetParser.parse(
            offsetString,
            primaryText: primaryText,
            otherText: otherText
        )
        guard !offsets.isEmpty else { return [] }
        let primaryLength = primaryText.utf16.count
        return nodes.filter { node in
            offsets.contains { offset in
                let shift: Int
                switch offset.column {
                case .primaryText:
                    guard node.windowIndex == 0 else { return false }
                    shift = 0
                case .otherText:
                    guard node.windowIndex != 0 else { return false }
                    shift = primaryLength
                }
                let lower = node.textOffset - shift
                let upper = lower + node.textLength
                // Include nodes that touch either edge of a match.
                return lower <= offset.upperBound && upper >= offset.lowerBound
            }
        }
    }
}

/// Geometry and opacity for OCR node overlays on the selected frame.
public enum FrameNodesVisualContract {
    public static let maskOpacity: CGFloat = 0.30
    public static let borderOpacity: CGFloat = 0.85
    public static let borderWidth: CGFloat = 1.5
    public static let cornerRadius: CGFloat = 5

    public static func projectedRect(
        node: OCRNode,
        imageSize: CGSize,
        contentSize: CGSize
    ) -> CGRect {
        SearchMatchVisualContract.projectedRect(
            node: node,
            imageSize: imageSize,
            contentSize: contentSize
        )
    }
}
#endif
