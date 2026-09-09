#if os(macOS)
import XCTest
@testable import LibreReverseCore

final class SearchCropRequestTests: XCTestCase {
    func testZoomedOutCropUsesFixedRetinaCardSizeAndTopLeadingInsets() {
        let match = CGRect(x: 96.7, y: 887.5, width: 145, height: 22)
        let crop = SearchCropRequest.sourceRectangle(
            match: match,
            targetSize: CGSize(width: 263, height: 174)
        )

        XCTAssertEqual(crop.minX, -3.3, accuracy: 0.0001)
        XCTAssertEqual(crop.minY, 787.5, accuracy: 0.0001)
        XCTAssertEqual(crop.width, 526, accuracy: 0.0001)
        XCTAssertEqual(crop.height, 348, accuracy: 0.0001)
    }

    func testCropDoesNotClampAnEdgeMatch() {
        let crop = SearchCropRequest.sourceRectangle(
            match: CGRect(x: 10, y: 10, width: 20, height: 10),
            targetSize: CGSize(width: 263, height: 174)
        )
        XCTAssertLessThan(crop.minX, 0)
        XCTAssertLessThan(crop.minY, 0)
    }
}
#endif
