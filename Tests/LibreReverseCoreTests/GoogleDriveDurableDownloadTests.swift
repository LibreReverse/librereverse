#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

final class GoogleDriveDurableDownloadTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var handler: ((Stub) -> Void)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let handler = Self.lock.withLock { Self.handler }
            handler?(self)
        }
        override func stopLoading() {}
        func reply(_ code: Int, headers: [String: String] = [:], data: Data, error: Error? = nil) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
                               httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if let error {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            } else { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    private func verifyRestart(serverHonorsRange: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<262_144).map { UInt8($0 % 251) })
        let prefix = 65_536
        let remote = RemoteObjectMetadata(identifier: "fixture", version: "1", key: ArchiveObjectKey("fixture"),
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let request = URLRequest(url: URL(string: "https://example.invalid/file")!)
        Stub.lock.withLock {
            Stub.handler = { stub in
                XCTAssertNil(stub.request.value(forHTTPHeaderField: "Range"))
                stub.reply(200, data: bytes.prefix(prefix), error: URLError(.networkConnectionLost))
            }
        }
        do {
            _ = try await GoogleDriveDurableDownload.run(request: request, remote: remote,
                destination: root.appendingPathComponent("first-attempt"), configuration: config) { _ in }
            XCTFail("Expected interrupted transfer")
        } catch {}
        // A new transport with a new resolver temporary filename must discover
        // the checkpoint using remote identity, without any in-memory state.
        Stub.lock.withLock {
            Stub.handler = { stub in
                XCTAssertEqual(stub.request.value(forHTTPHeaderField: "Range"), "bytes=\(prefix)-")
                if serverHonorsRange {
                    stub.reply(206, headers: ["Content-Range": "bytes \(prefix)-\(bytes.count - 1)/\(bytes.count)"],
                               data: bytes.dropFirst(prefix))
                } else {
                    stub.reply(200, data: bytes)
                }
            }
        }
        let destination = root.appendingPathComponent("after-restart")
        _ = try await GoogleDriveDurableDownload.run(request: request, remote: remote,
            destination: destination, configuration: config) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        // Installation may be interrupted too: a complete checkpoint remains
        // available until the resolver explicitly commits its canonical file.
        Stub.lock.withLock { Stub.handler = { _ in XCTFail("Completed checkpoint should not redownload") } }
        let installationRetry = root.appendingPathComponent("installation-retry")
        _ = try await GoogleDriveDurableDownload.run(request: request, remote: remote,
            destination: installationRetry, configuration: config) { _ in }
        XCTAssertEqual(try Data(contentsOf: installationRetry), bytes)
        GoogleDriveDurableDownload.release(remote, temporaryURL: destination)
        let leftovers = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("DownloadCache"), includingPropertiesForKeys: nil)
        XCTAssertFalse(leftovers.contains { $0.pathExtension == "partial" })
    }

    func testNewTransportResumesPersistedBytesAfterInterruption() async throws {
        try await verifyRestart(serverHonorsRange: true)
    }
    func testServerIgnoringRangeReplacesPrefixInsteadOfAppendingCorruptData() async throws {
        try await verifyRestart(serverHonorsRange: false)
    }
}
#endif
