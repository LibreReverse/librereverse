#if os(macOS)
import AppKit
import Foundation
import XCTest

@testable import LibreReverseApp

@MainActor
final class FaviconResolverTests: XCTestCase {
    func testAssetKeysNormalizeHostsAndRejectPathTraversal() {
        XCTAssertEqual(
            LibreReverseFaviconResolver.assetKeys(for: "WWW.Amazon.com."),
            ["www_amazon_com", "amazon_com"]
        )
        XCTAssertEqual(
            LibreReverseFaviconResolver.assetKeys(for: "dashboard.clerk.com"),
            ["dashboard_clerk_com"]
        )
        XCTAssertTrue(LibreReverseFaviconResolver.assetKeys(for: "../../Secrets").isEmpty)
        XCTAssertTrue(LibreReverseFaviconResolver.assetKeys(for: "example.com/path").isEmpty)
    }

    func testOwnedCachePrecedesBundleAndUnknownHostsRemainLocal() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: bundle.appendingPathComponent("github_com.png"))
        try Self.onePixelPNG.write(to: bundle.appendingPathComponent("bundle_example.png"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        bitmap.setColor(.blue, atX: 1, y: 0)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: cache.appendingPathComponent("github_com.png"))

        let resolver = LibreReverseFaviconResolver(
            cacheRoot: cache,
            bundledRoot: bundle
        )
        XCTAssertEqual(resolver.image(for: "github.com")?.representations.first?.pixelsWide, 2)
        XCTAssertNotNil(resolver.image(for: "bundle.example"))
        XCTAssertNil(resolver.image(for: "unknown.example"))
        XCTAssertEqual(LibreReverseFaviconResolver.monogram(for: "unknown.example"), "U")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["github_com.png"])
        try FileManager.default.removeItem(at: cache.appendingPathComponent("github_com.png"))
        let bundleOnly = LibreReverseFaviconResolver(
            cacheRoot: cache,
            bundledRoot: bundle
        )
        XCTAssertEqual(bundleOnly.image(for: "github.com")?.representations.first?.pixelsWide, 1)
    }

    func testInvalidImageFallsBackWithoutPoisoningOtherDomains() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(
            to: root.appendingPathComponent("broken_example.png"),
            options: .atomic
        )
        try Self.onePixelPNG.write(
            to: root.appendingPathComponent("working_example.png"),
            options: .atomic
        )
        let resolver = LibreReverseFaviconResolver(
            cacheRoot: root,
            bundledRoot: nil
        )
        XCTAssertNil(resolver.image(for: "broken.example"))
        XCTAssertNotNil(resolver.image(for: "working.example"))
    }

    func testMonogramAndColorAreStableAndLocal() {
        XCTAssertEqual(LibreReverseFaviconResolver.monogram(for: "www.github.com"), "G")
        XCTAssertEqual(LibreReverseFaviconResolver.monogram(for: ""), "?")
        XCTAssertEqual(
            LibreReverseFaviconResolver.hue(for: "GitHub.com"),
            LibreReverseFaviconResolver.hue(for: "github.com")
        )
        XCTAssertNotEqual(
            LibreReverseFaviconResolver.hue(for: "github.com"),
            LibreReverseFaviconResolver.hue(for: "amazon.com")
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "librereverse-favicon-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}
#endif
