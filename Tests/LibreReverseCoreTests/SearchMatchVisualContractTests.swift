#if os(macOS)
import CoreGraphics
import XCTest
@testable import LibreReverseCore

final class SearchMatchVisualContractTests: XCTestCase {
    func testRecoveredDrawingConstantsStayExact() {
        XCTAssertEqual(SearchMatchVisualContract.maskOpacity, 0.30)
        XCTAssertEqual(SearchMatchVisualContract.borderOpacity, 0.85)
        XCTAssertEqual(SearchMatchVisualContract.borderWidth, 1.5)
        XCTAssertEqual(SearchMatchVisualContract.cornerRadius, 5)
        XCTAssertEqual(SearchMatchVisualContract.displayP3Red, 1)
        XCTAssertEqual(
            SearchMatchVisualContract.displayP3Green,
            0.902000010014,
            accuracy: 0.000000000001
        )
        XCTAssertEqual(SearchMatchVisualContract.displayP3Blue, 0)
    }

    func testProjectsTopLeftNodeIntoHorizontalAspectFitLetterbox() {
        let node = OCRNode(
            nodeOrder: 0,
            textOffset: 0,
            textLength: 1,
            leftX: 0.1,
            topY: 0.2,
            width: 0.3,
            height: 0.4,
            windowIndex: 0
        )
        let rect = SearchMatchVisualContract.projectedRect(
            node: node,
            imageSize: CGSize(width: 200, height: 100),
            contentSize: CGSize(width: 300, height: 300)
        )
        XCTAssertEqual(rect.origin.x, 30, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 135, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 90, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.0001)
    }

    func testProjectsTopLeftNodeIntoVerticalAspectFitLetterbox() {
        let node = OCRNode(
            nodeOrder: 0,
            textOffset: 0,
            textLength: 1,
            leftX: 0.1,
            topY: 0.2,
            width: 0.3,
            height: 0.4,
            windowIndex: 0
        )
        let rect = SearchMatchVisualContract.projectedRect(
            node: node,
            imageSize: CGSize(width: 100, height: 200),
            contentSize: CGSize(width: 300, height: 200)
        )
        XCTAssertEqual(rect.origin.x, 110, accuracy: 0.0001)
        XCTAssertEqual(rect.origin.y, 80, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 30, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 80, accuracy: 0.0001)
    }
}
#endif
