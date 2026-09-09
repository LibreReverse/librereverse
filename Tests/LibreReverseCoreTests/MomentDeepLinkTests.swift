import Foundation
import XCTest
@testable import LibreReverseCore

final class MomentDeepLinkTests: XCTestCase {
    func testNewLinksUseNativeSchemeAndUnixTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_708_012_345.125)
        let url = try XCTUnwrap(MomentDeepLink.url(for: date))

        XCTAssertEqual(
            url.absoluteString,
            "librereverse://show-moment?timestamp=1708012345.125"
        )
        XCTAssertEqual(MomentDeepLink.date(from: url), date)
    }

    func testMalformedOrUnrelatedLinksFailClosed() {
        for value in [
            "https://show-moment?timestamp=42",
            "librereverse://settings?timestamp=42",
            "librereverse://show-moment/path?timestamp=42",
            "librereverse://show-moment?timestamp=nan",
            "librereverse://show-moment?timestamp=",
        ] {
            XCTAssertNil(MomentDeepLink.date(from: URL(string: value)!))
        }
    }
}
