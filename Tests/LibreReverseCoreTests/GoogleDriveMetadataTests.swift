import XCTest
@testable import LibreReverseCore

final class GoogleDriveMetadataTests: XCTestCase {
    func testRootDiscoveryRequiresItsPrivateMarker() {
        XCTAssertEqual(GoogleDriveMetadata.value(.root, in: ["librereverseRoot": "1"]), "1")
        XCTAssertNil(GoogleDriveMetadata.value(.root, in: ["unrelatedRoot": "1"]))
        XCTAssertNil(GoogleDriveMetadata.value(.root, in: nil))
        XCTAssertEqual(GoogleDriveMetadata.query(.root, equals: "1"),
                       "appProperties has { key='librereverseRoot' and value='1' }")
    }

    func testIdentityQueryEscapesQuotesAndBackslashes() {
        XCTAssertEqual(GoogleDriveMetadata.query(.objectKey, equals: "video/a'b\\c"),
                       "appProperties has { key='librereverseObjectKey' and value='video/a\\'b\\\\c' }")
    }
}
