import CoreGraphics
import XCTest
@testable import LibreReverseCore

final class OCRTextAssemblyTests: XCTestCase {
    func testAssemblesOrderingPartitionOffsetsAndTopLeftGeometry() {
        let observations = [
            OCRObservation(
                text: "background top",
                boundingBox: CGRect(x: 0.05, y: 0.80, width: 0.20, height: 0.05)
            ),
            OCRObservation(
                text: "front top",
                boundingBox: CGRect(x: 0.65, y: 0.80, width: 0.20, height: 0.05)
            ),
            OCRObservation(
                text: "background bottom",
                boundingBox: CGRect(x: 0.05, y: 0.10, width: 0.25, height: 0.05)
            ),
            OCRObservation(
                text: "front bottom",
                boundingBox: CGRect(x: 0.65, y: 0.10, width: 0.20, height: 0.05)
            ),
        ]

        let result = OCRTextAssembly.assemble(
            observations: observations,
            normalizedFrontWindowBounds: CGRect(x: 0.60, y: 0, width: 0.40, height: 1)
        )

        XCTAssertEqual(result.text, "front bottom front top")
        XCTAssertEqual(result.otherText, "background bottom background top")
        XCTAssertEqual(result.nodes.map(\.nodeOrder), [0, 1, 2, 3])
        XCTAssertEqual(result.nodes.map(\.windowIndex), [0, 0, 1, 1])
        XCTAssertEqual(result.nodes.map(\.textOffset), [0, 13, 22, 40])
        XCTAssertEqual(result.nodes.map(\.textLength), [12, 9, 17, 14])
        XCTAssertEqual(result.nodes[0].leftX, 0.65, accuracy: 1e-12)
        XCTAssertEqual(result.nodes[0].topY, 0.85, accuracy: 1e-12)
        XCTAssertEqual(result.nodes[0].width, 0.20, accuracy: 1e-12)
        XCTAssertEqual(result.nodes[0].height, 0.05, accuracy: 1e-12)
    }

    func testFrontPartitionRequiresStrictlyMoreThanHalfIntersection() {
        let window = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let exactlyHalf = OCRObservation(
            text: "half",
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)
        )
        let overHalf = OCRObservation(
            text: "over",
            boundingBox: CGRect(x: 0.251, y: 0.5, width: 0.5, height: 0.25)
        )

        let result = OCRTextAssembly.assemble(
            observations: [exactlyHalf, overHalf],
            normalizedFrontWindowBounds: window
        )

        XCTAssertEqual(result.text, "over")
        XCTAssertEqual(result.otherText, "half")
    }

    func testOffsetsUseUTF16CodeUnitsAndNoColumnSeparator() {
        let result = OCRTextAssembly.assemble(
            observations: [
                .init(text: "other", boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.1)),
                .init(text: "e\u{301}", boundingBox: .init(x: 0.8, y: 0, width: 0.1, height: 0.1)),
                .init(text: "front", boundingBox: .init(x: 0.8, y: 0.2, width: 0.1, height: 0.1)),
            ],
            normalizedFrontWindowBounds: .init(x: 0.7, y: 0, width: 0.3, height: 1)
        )

        XCTAssertEqual(result.text, "front e\u{301}")
        XCTAssertEqual(result.text.count, 7)
        XCTAssertEqual(result.text.utf16.count, 8)
        XCTAssertEqual(result.nodes.map(\.textOffset), [0, 6, 8])
        XCTAssertEqual(result.nodes.map(\.textLength), [5, 2, 5])
    }

    func testOffsetsCountSurrogatePairsAsTwoUTF16CodeUnits() {
        let result = OCRTextAssembly.assemble(
            observations: [
                .init(text: "tail", boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.1)),
                .init(text: "after", boundingBox: .init(x: 0.8, y: 0, width: 0.1, height: 0.1)),
                .init(text: "😀", boundingBox: .init(x: 0.8, y: 0.2, width: 0.1, height: 0.1)),
            ],
            normalizedFrontWindowBounds: .init(x: 0.7, y: 0, width: 0.3, height: 1)
        )

        XCTAssertEqual(result.text, "😀 after")
        XCTAssertEqual(result.nodes.map(\.textOffset), [0, 3, 8])
        XCTAssertEqual(result.nodes.map(\.textLength), [2, 5, 4])
    }

    func testNormalizesWindowBoundsRelativeToDisplayOriginAndSize() {
        XCTAssertEqual(
            OCRTextAssembly.normalizedWindowBounds(
                displayBounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
                frontWindowBounds: CGRect(x: 600, y: 150, width: 400, height: 250)
            ),
            CGRect(x: 0.5, y: 0.2, width: 0.4, height: 0.5)
        )
    }

    func testPartitionsAfterFlippingVisionYIntoWindowServerCoordinates() {
        let result = OCRTextAssembly.assemble(
            observations: [
                .init(
                    text: "screen bottom",
                    boundingBox: .init(x: 0.2, y: 0.05, width: 0.2, height: 0.1)
                ),
                .init(
                    text: "screen top",
                    boundingBox: .init(x: 0.2, y: 0.85, width: 0.2, height: 0.1)
                ),
            ],
            normalizedFrontWindowBounds: .init(x: 0, y: 0, width: 1, height: 0.25)
        )
        XCTAssertEqual(result.text, "screen top")
        XCTAssertEqual(result.otherText, "screen bottom")
    }

    func testMissingWindowGeometryTreatsAllTextAsFront() {
        let result = OCRTextAssembly.assemble(
            observations: [
                .init(text: "second", boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1)),
                .init(text: "first", boundingBox: .init(x: 0, y: 0.2, width: 0.1, height: 0.1)),
            ],
            normalizedFrontWindowBounds: nil
        )
        XCTAssertEqual(result.text, "first second")
        XCTAssertEqual(result.otherText, "")
        XCTAssertEqual(result.nodes.map(\.windowIndex), [0, 0])
    }
}
