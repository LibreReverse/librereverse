#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseCore

final class LibraryDatabaseDateTests: XCTestCase {
    func testCanonicalDatesMatchFoundationAcrossLeapAndCenturyBoundaries() throws {
        for year in [1900, 1969, 1970, 1999, 2000, 2024, 2026, 2099, 2100, 2400, 9999] {
            for month in 1...12 {
                for day in [1, 28] {
                    let value = String(format: "%04d-%02d-%02dT23:59:58.123", year, month, day)
                    let expected = try XCTUnwrap(LibraryDatabase.databaseFormatter.date(from: value))
                    let actual = try XCTUnwrap(LibraryDatabase.canonicalDatabaseDate(value))
                    XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0001, value)
                }
            }
        }
        for value in ["2000-02-29T00:00:00.000", "2024-02-29T12:30:45.999", "1970-01-01T00:00:00.001"] {
            XCTAssertEqual(try XCTUnwrap(LibraryDatabase.canonicalDatabaseDate(value)).timeIntervalSince1970,
                try XCTUnwrap(LibraryDatabase.databaseFormatter.date(from: value)).timeIntervalSince1970,
                accuracy: 0.0001)
        }
    }

    func testNoncanonicalDatesKeepFormatterBehavior() throws {
        for value in ["2026-09-06T12:34:56.1", "2026-09-06T12:34:56.1234", "1899-12-31T23:59:59.999",
                      "1900-02-29T00:00:00.000", "2026-13-01T00:00:00.000", "2026-01-32T00:00:00.000",
                      "2026-01-01T24:00:00.000", "2026-01-01T00:60:00.000", "2026-01-01T00:00:60.000",
                      "invalid", "２０２６-09-06T12:34:56.000"] {
            XCTAssertNil(LibraryDatabase.canonicalDatabaseDate(value), value)
            if let expected = LibraryDatabase.databaseFormatter.date(from: value) {
                XCTAssertEqual(try LibraryDatabase.databaseDate(value), expected, value)
            } else {
                XCTAssertThrowsError(try LibraryDatabase.databaseDate(value), value)
            }
        }
    }

    func testCanonicalParsingBenchmark() throws {
        let values = (0..<5000).map { String(format: "2026-09-06T12:%02d:%02d.%03d", ($0 / 60) % 60, $0 % 60, $0 % 1000) }
        var baselineSum = 0.0
        var fastSum = 0.0
        let start = Date()
        for value in values { baselineSum += try XCTUnwrap(LibraryDatabase.databaseFormatter.date(from: value)).timeIntervalSince1970 }
        let baseline = Date().timeIntervalSince(start)
        let fastStart = Date()
        for value in values { fastSum += try LibraryDatabase.databaseDate(value).timeIntervalSince1970 }
        let fast = Date().timeIntervalSince(fastStart)
        XCTAssertEqual(fastSum, baselineSum, accuracy: 0.01)
        print("Database date benchmark: 5000 rows Foundation=\(baseline)s canonical=\(fast)s")
    }
}
#endif
