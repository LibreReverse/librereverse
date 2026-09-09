#if os(macOS)
import CFPNG
import Foundation
import XCTest

final class CFPNGContractTests: XCTestCase {
    private func encode(_ context: OpaquePointer?, bytes: [UInt8], accessible: Int? = nil,
                        width: UInt32 = 1, height: UInt32 = 1, stride: Int = 4,
                        ignoreAlpha: Int32 = 0) -> (CFPNGResult, Data?) {
        var output = UnsafePointer<UInt8>(bitPattern: 1)
        var count = 123
        let result = bytes.withUnsafeBufferPointer {
            cf_png_encode_bgra8(context, $0.baseAddress, accessible ?? $0.count,
                               width, height, stride, ignoreAlpha, &output, &count)
        }
        if result != CFPNG_SUCCESS {
            XCTAssertNil(output, "Every failure must clear a previous borrowed output pointer")
            XCTAssertEqual(count, 0, "Every failure must clear a previous byte count")
            return (result, nil)
        }
        guard let output else { XCTFail("Successful encoding requires output"); return (result, nil) }
        XCTAssertGreaterThan(count, 0)
        return (result, Data(bytes: output, count: count))
    }

    func testInvalidBoundsAndFlagsRejectBeforeReadingAndClearOutputs() throws {
        let context = try XCTUnwrap(cf_png_create(1024))
        defer { cf_png_destroy(context) }
        let tiny: [UInt8] = [10, 20, 30, 255]
        XCTAssertEqual(encode(nil, bytes: tiny).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, width: 0).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, height: 0).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, stride: 3).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, accessible: 3).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, height: 2, stride: Int.max).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, height: 4, stride: Int.max).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: tiny, width: UInt32.max).0, CFPNG_LIMIT_EXCEEDED)
        XCTAssertEqual(encode(context, bytes: tiny, height: UInt32.max).0, CFPNG_LIMIT_EXCEEDED)
        XCTAssertEqual(encode(context, bytes: tiny, width: 17, height: 17, stride: 68).0, CFPNG_LIMIT_EXCEEDED)
        for flag: Int32 in [-1, 2, Int32.max] {
            XCTAssertEqual(encode(context, bytes: tiny, ignoreAlpha: flag).0, CFPNG_INVALID_ARGUMENT)
        }
        // Rejection must not poison subsequent valid work.
        XCTAssertEqual(encode(context, bytes: tiny).0, CFPNG_SUCCESS)
    }

    func testNullPointersAndInvalidContextLimitsHaveSafeOutParameters() throws {
        XCTAssertNil(cf_png_create(0))
        XCTAssertNil(cf_png_create(256 * 1024 * 1024 + 1))
        cf_png_reset(nil)
        cf_png_destroy(nil)
        XCTAssertEqual(cf_png_retained_bytes(nil), 0)
        let context = try XCTUnwrap(cf_png_create(1024))
        defer { cf_png_destroy(context) }
        var output = UnsafePointer<UInt8>(bitPattern: 1)
        var count = 123
        XCTAssertEqual(cf_png_encode_bgra8(context, nil, 4, 1, 1, 4, 0, &output, &count), CFPNG_INVALID_ARGUMENT)
        XCTAssertNil(output); XCTAssertEqual(count, 0)
        let bytes: [UInt8] = [10, 20, 30, 255]
        bytes.withUnsafeBufferPointer { pixels in
            count = 123
            XCTAssertEqual(cf_png_encode_bgra8(context, pixels.baseAddress, 4, 1, 1, 4, 0, nil, &count), CFPNG_INVALID_ARGUMENT)
            XCTAssertEqual(count, 0)
            output = UnsafePointer<UInt8>(bitPattern: 1)
            XCTAssertEqual(cf_png_encode_bgra8(context, pixels.baseAddress, 4, 1, 1, 4, 0, &output, nil), CFPNG_INVALID_ARGUMENT)
            XCTAssertNil(output)
        }
    }

    func testLastRowNeedsOnlyVisibleBytesAndTransparencyRequiresExplicitSkipAlpha() throws {
        let context = try XCTUnwrap(cf_png_create(4096))
        defer { cf_png_destroy(context) }
        let width: UInt32 = 17, stride = 96, height: UInt32 = 2
        var bytes = [UInt8](repeating: 0xCD, count: stride + Int(width) * 4)
        for row in 0..<Int(height) {
            for x in 0..<Int(width) {
                bytes[row * stride + x * 4 + 3] = 255
            }
        }
        XCTAssertEqual(encode(context, bytes: bytes, accessible: bytes.count - 1,
            width: width, height: height, stride: stride).0, CFPNG_INVALID_ARGUMENT)
        XCTAssertEqual(encode(context, bytes: bytes, width: width, height: height, stride: stride).0, CFPNG_SUCCESS)
        // Exercise opacity rejection in both SIMD-sized runs and scalar tails.
        for alphaPosition in [3, stride + 16 * 4 + 3] {
            var transparent = bytes
            transparent[alphaPosition] = 0
            XCTAssertEqual(encode(context, bytes: transparent, width: width, height: height,
                stride: stride).0, CFPNG_UNSUPPORTED_ALPHA)
            XCTAssertEqual(encode(context, bytes: transparent, width: width, height: height,
                stride: stride, ignoreAlpha: 1).0, CFPNG_SUCCESS)
        }
    }

    func testResetReleasesRetainedStorageAndEncoderCanBeReused() throws {
        let context = try XCTUnwrap(cf_png_create(4096))
        defer { cf_png_destroy(context) }
        let bytes = [UInt8](repeating: 255, count: 17 * 13 * 4)
        let original = try XCTUnwrap(encode(context, bytes: bytes, width: 17, height: 13, stride: 68).1)
        XCTAssertGreaterThan(cf_png_retained_bytes(context), 0)
        cf_png_reset(context)
        XCTAssertEqual(cf_png_retained_bytes(context), 0)
        let repeated = try XCTUnwrap(encode(context, bytes: bytes, width: 17, height: 13, stride: 68).1)
        XCTAssertEqual(repeated, original)
        XCTAssertGreaterThan(cf_png_retained_bytes(context), 0)
    }
}
#endif
