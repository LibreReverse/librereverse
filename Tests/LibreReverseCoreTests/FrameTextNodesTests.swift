#if os(macOS)
import CoreGraphics
import XCTest
@testable import LibreReverseCore

final class FrameTextNodesTests: XCTestCase {
    func testResolverMarksEveryOverlappingNodeInItsMatchingTextColumn() {
        let primary = "front needle"
        let other = "behind"
        let primaryLength = primary.utf16.count
        let nodes = [
            node(order: 0, offset: 0, length: 5, window: 0),
            node(order: 1, offset: 6, length: 6, window: 0),
            node(order: 2, offset: primaryLength, length: 6, window: 1),
            node(order: 3, offset: primaryLength + 1, length: 6, window: 0),
        ]

        let matches = FrameTextNodeResolver.matchingNodes(
            nodes,
            offsetString: "0 0 6 6 1 1 0 6",
            primaryText: primary,
            otherText: other
        )

        XCTAssertEqual(matches.map(\.nodeOrder), [1, 2])
    }

    func testResolverUsesInclusiveBoundaryOverlap() {
        let nodes = [
            node(order: 0, offset: 0, length: 6, window: 0),
            node(order: 1, offset: 12, length: 2, window: 0),
            node(order: 2, offset: 13, length: 1, window: 0),
        ]

        let matches = FrameTextNodeResolver.matchingNodes(
            nodes,
            offsetString: "0 0 6 6",
            primaryText: "front needle",
            otherText: ""
        )

        XCTAssertEqual(
            matches.map(\.nodeOrder),
            [0, 1],
            "nodeEnd == matchLower and nodeStart == matchUpper both overlap"
        )
    }

    func testResolverPreservesNodeOrderAndUTF16CorrectedOffsets() {
        let primary = "a😀 needle"
        let nodes = [
            node(order: 8, offset: 4, length: 6, window: 0),
            node(order: 3, offset: 4, length: 6, window: 0),
        ]

        let matches = FrameTextNodeResolver.matchingNodes(
            nodes,
            // UTF-8 byte offset 6 is UTF-16 offset 4 after a + emoji.
            offsetString: "0 0 6 6",
            primaryText: primary,
            otherText: ""
        )

        XCTAssertEqual(matches.map(\.nodeOrder), [8, 3])
    }

    func testFrameNodesVisualContractPinsRecoveredConstantsAndProjection() {
        XCTAssertEqual(FrameNodesVisualContract.maskOpacity, 0.30)
        XCTAssertEqual(FrameNodesVisualContract.borderOpacity, 0.85)
        XCTAssertEqual(FrameNodesVisualContract.borderWidth, 1.5)
        XCTAssertEqual(FrameNodesVisualContract.cornerRadius, 5)
        let projected = FrameNodesVisualContract.projectedRect(
            node: node(
                order: 0,
                offset: 0,
                length: 1,
                window: 0,
                leftX: 0.1,
                topY: 0.2,
                width: 0.3,
                height: 0.4
            ),
            imageSize: CGSize(width: 200, height: 100),
            contentSize: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(projected.origin.x, 30, accuracy: 0.0001)
        XCTAssertEqual(projected.origin.y, 135, accuracy: 0.0001)
        XCTAssertEqual(projected.width, 90, accuracy: 0.0001)
        XCTAssertEqual(projected.height, 60, accuracy: 0.0001)
    }

    private func node(
        order: Int,
        offset: Int,
        length: Int,
        window: Int,
        leftX: Double = 0,
        topY: Double = 0,
        width: Double = 0.1,
        height: Double = 0.1
    ) -> OCRNode {
        OCRNode(
            nodeOrder: order,
            textOffset: offset,
            textLength: length,
            leftX: leftX,
            topY: topY,
            width: width,
            height: height,
            windowIndex: window
        )
    }
}
#endif
