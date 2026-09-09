import CryptoKit
import XCTest
@testable import LibreReverseApp

final class UpdaterTests: XCTestCase {
    func testSignedHTTPSManifestOffersOnlyANewerBuild() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = LibreReverseUpdateManifest(
            version: "2.0",
            build: 20,
            downloadURL: URL(string: "https://example.com/LibreReverse-2.0.zip")!,
            releaseNotesURL: URL(string: "https://example.com/releases/2.0")!,
            sha256: String(repeating: "a", count: 64)
        )
        let payload = try JSONEncoder().encode(manifest)
        let envelope = LibreReverseSignedUpdateEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/update.json")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let checker = LibreReverseUpdateChecker(
            configuration: .init(
                manifestURL: response.url!,
                publicKey: privateKey.publicKey.rawRepresentation
            ),
            currentBuild: 12,
            fetch: { _ in (envelopeData, response) }
        )

        let result = try await checker.check()
        XCTAssertEqual(result, .available(manifest))
    }

    func testInvalidSignatureAndUnsafeDownloadFailClosed() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let verificationKey = Curve25519.Signing.PrivateKey().publicKey
        let unsafe = LibreReverseUpdateManifest(
            version: "2.0",
            build: 20,
            downloadURL: URL(string: "http://example.com/LibreReverse.zip")!,
            releaseNotesURL: nil,
            sha256: String(repeating: "b", count: 64)
        )
        let payload = try JSONEncoder().encode(unsafe)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/update.json")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        func checker(key: Data, signature: Data) throws -> LibreReverseUpdateChecker {
            let envelope = LibreReverseSignedUpdateEnvelope(
                payload: payload.base64EncodedString(),
                signature: signature.base64EncodedString()
            )
            let data = try JSONEncoder().encode(envelope)
            return .init(
                configuration: .init(manifestURL: response.url!, publicKey: key),
                currentBuild: 12,
                fetch: { _ in (data, response) }
            )
        }

        let wrongSignature = try signingKey.signature(for: payload)
        do {
            _ = try await checker(
                key: verificationKey.rawRepresentation,
                signature: wrongSignature
            ).check()
            XCTFail("expected signature rejection")
        } catch {
            XCTAssertEqual(error as? LibreReverseUpdateError, .invalidSignature)
        }

        let validSignature = try signingKey.signature(for: payload)
        do {
            _ = try await checker(
                key: signingKey.publicKey.rawRepresentation,
                signature: validSignature
            ).check()
            XCTFail("expected unsafe URL rejection")
        } catch {
            XCTAssertEqual(error as? LibreReverseUpdateError, .invalidManifest)
        }
    }

    func testDownloadedUpdateMustMatchSignedSHA256BeforeItIsExposed() async throws {
        let bytes = Data("verified LibreReverse update".utf8)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".download"
        )
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/LibreReverse.zip")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let manifest = LibreReverseUpdateManifest(
            version: "2.0 beta",
            build: 20,
            downloadURL: response.url!,
            releaseNotesURL: nil,
            sha256: digest
        )
        let downloader = LibreReverseUpdateDownloader(
            download: { _ in (source, response) }
        )

        let verified = try await downloader.downloadAndVerify(
            manifest,
            destinationDirectory: destinationDirectory
        )
        XCTAssertEqual(verified.lastPathComponent, "LibreReverse-2.0-beta.zip")
        XCTAssertEqual(try Data(contentsOf: verified), bytes)

        try bytes.write(to: source)
        let corrupt = LibreReverseUpdateManifest(
            version: manifest.version,
            build: manifest.build,
            downloadURL: manifest.downloadURL,
            releaseNotesURL: nil,
            sha256: String(repeating: "0", count: 64)
        )
        do {
            _ = try await downloader.downloadAndVerify(
                corrupt,
                destinationDirectory: destinationDirectory
            )
            XCTFail("expected integrity rejection")
        } catch {
            XCTAssertEqual(error as? LibreReverseUpdateError, .downloadIntegrityMismatch)
        }
    }
}
