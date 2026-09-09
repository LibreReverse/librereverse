#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

final class S3MultipartArchiveBackendTests: XCTestCase {
    private static let partBytes = 5 * 1024 * 1024
    private let libraryID = "12345678123412341234123456789abc"
    private var key: ArchiveObjectKey { .init("libraries/\(libraryID)/database-shard/00000000000000000001/fixture.sqlite3") }

    private final class Stub: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var server: Server?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let server = try XCTUnwrap(Self.lock.withLock { Self.server })
                let (status, headers, data) = try server.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        let data: Data
        private var requests: [URLRequest] = []
        var failPartOnce: Int?
        var completionError = false
        var loseCompletionResponseOnce = false
        var completed = false
        var corruptDownload = false
        var corruptPartChecksum = false
        var expirePartUpload = false
        init(data: Data) { self.data = data }
        var calls: [URLRequest] { lock.withLock { requests } }
        var uploadedParts: [Int] { calls.compactMap { $0.httpMethod == "PUT" ? Self.query($0, "partNumber").flatMap(Int.init) : nil } }
        static func query(_ request: URLRequest, _ name: String) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) {
            try lock.withLock {
                requests.append(request)
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                if request.httpMethod == "POST", Self.query(request, "uploads") != nil {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-checksum-algorithm"), "SHA256")
                    return (200, [:], Data("<InitiateMultipartUploadResult><UploadId>upload+fixture/1=</UploadId></InitiateMultipartUploadResult>".utf8))
                }
                if request.httpMethod == "PUT", let text = Self.query(request, "partNumber"), let part = Int(text) {
                    XCTAssertEqual(Self.query(request, "uploadId"), "upload+fixture/1=")
                    XCTAssertNil(request.httpBody, "Part upload must be file backed")
                    let start = (part - 1) * S3MultipartArchiveBackendTests.partBytes
                    let chunk = data.subdata(in: start..<min(start + S3MultipartArchiveBackendTests.partBytes, data.count))
                    let checksum = Data(SHA256.hash(data: chunk)).base64EncodedString()
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(chunk.count))
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-checksum-sha256"), checksum)
                    if expirePartUpload { return (404, [:], Data("<Error><Code>NoSuchUpload</Code></Error>".utf8)) }
                    if corruptPartChecksum { return (200, ["ETag": "\"part-\(part)\"", "x-amz-checksum-sha256": "bad"], Data()) }
                    if failPartOnce == part { failPartOnce = nil; return (503, [:], Data()) }
                    return (200, ["ETag": "\"part-\(part)\"", "x-amz-checksum-sha256": checksum], Data())
                }
                if request.httpMethod == "POST", Self.query(request, "uploadId") != nil {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                    if completed { return (404, [:], Data("<Error><Code>NoSuchUpload</Code></Error>".utf8)) }
                    if completionError { return (200, [:], Data("<Error><Code>InternalError</Code><Message>fixture</Message></Error>".utf8)) }
                    completed = true
                    if loseCompletionResponseOnce { loseCompletionResponseOnce = false; throw URLError(.networkConnectionLost) }
                    return (200, [:], Data("<CompleteMultipartUploadResult><ETag>\"multipart-3\"</ETag></CompleteMultipartUploadResult>".utf8))
                }
                if request.httpMethod == "DELETE", Self.query(request, "uploadId") != nil {
                    return (204, [:], Data())
                }
                if request.httpMethod == "HEAD" {
                    guard completed else { return (404, [:], Data()) }
                    // This is deliberately a composite SHA, never a whole-file checksum.
                    return (200, ["Content-Length": String(data.count), "ETag": "\"multipart-3\"",
                        "x-amz-checksum-type": "COMPOSITE", "x-amz-checksum-sha256": Data(SHA256.hash(data: data)).base64EncodedString() + "-3"], Data())
                }
                if request.httpMethod == "GET" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"multipart-3\"")
                    var body = data
                    if corruptDownload { body[0] ^= 1 }
                    return (200, ["Content-Length": String(body.count)], body)
                }
                XCTFail("Unexpected multipart request: \(request.httpMethod ?? "")")
                return (500, [:], Data())
            }
        }
    }
    private actor Checkpoints {
        private var values: [ArchiveUploadSession] = []
        func save(_ value: ArchiveUploadSession) { values.append(value) }
        var last: ArchiveUploadSession? { values.last }
        var progress: [Int64] { values.map(\.acknowledgedBytes) }
    }
    private func backend(_ server: Server) throws -> S3ArchiveBackend {
        Stub.lock.withLock { Stub.server = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return try S3ArchiveBackend(configuration: .init(endpoint: URL(string: "https://s3.example.test")!,
            bucket: "test-bucket", accessKey: "fixture-access", secretKey: "fixture-secret"), libraryID: libraryID,
            session: URLSession(configuration: configuration), multipartThresholdBytes: 1,
            multipartPartBytes: Int64(Self.partBytes))
    }
    private func fixture() -> Data {
        let block = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var result = Data(capacity: Self.partBytes * 2 + 11)
        for _ in 0..<(Self.partBytes * 2 / block.count) { result.append(block) }
        result.append(block.prefix(11))
        return result
    }
    private func integrity(_ data: Data) -> ArchiveIntegrity {
        .init(byteCount: Int64(data.count), sha256: S3SignatureV4.hex(SHA256.hash(data: data)))
    }
    private func request(_ data: Data) -> ArchiveUploadRequest {
        .init(key: key, displayName: "fixture shard", objectKind: .databaseShard, subjectID: 1,
              relativePath: "fixture.sqlite3", contentType: "application/octet-stream", integrity: integrity(data))
    }
    private func file(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("s3-multipart-test-\(UUID().uuidString)")
        try data.write(to: path); return path
    }

    func testShardOverFiveGBBeginsWithoutAllocatingOrNetworking() async throws {
        let server = Server(data: Data()), b = try backend(server)
        let bytes: Int64 = 5_000_000_001
        let upload = try await b.beginUpload(.init(key: key, displayName: "large shard", objectKind: .databaseShard,
            subjectID: 1, relativePath: "large.sqlite3", contentType: "application/octet-stream", integrity: .init(byteCount: bytes, sha256: String(repeating: "a", count: 64))))
        XCTAssertEqual(upload.totalBytes, bytes)
        XCTAssertEqual(upload.acknowledgedBytes, 0)
        XCTAssertTrue(server.calls.isEmpty)
    }

    func testMultipartShardRoundTripAndCompositeChecksumVerification() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        let target = source.appendingPathExtension("hydrated")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let saved = Checkpoints()
        let result = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { await saved.save($0) }
        XCTAssertEqual(server.uploadedParts, [1, 2, 3])
        let progress = await saved.progress
        XCTAssertTrue(progress.contains(Int64(Self.partBytes)))
        XCTAssertTrue(progress.contains(Int64(Self.partBytes * 2)))
        XCTAssertEqual(progress.last, Int64(data.count))
        XCTAssertNil(result.metadata.sha256, "Composite checksums must not be trusted as whole-file SHA256")
        let verified = try await b.verify(result.metadata, expected: integrity(data))
        XCTAssertTrue(verified.matches)
        try await b.download(verified.metadata, to: target, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(server.calls.filter { $0.httpMethod == "GET" }.count, 2)
    }

    func testRestartResumesOnlyUnacknowledgedParts() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        let saved = Checkpoints()
        server.failPartOnce = 2
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { await saved.save($0) }
            XCTFail("Part failure must interrupt the upload")
        } catch {}
        let latest = await saved.last
        let checkpoint = try XCTUnwrap(latest)
        XCTAssertEqual(checkpoint.acknowledgedBytes, Int64(Self.partBytes))
        // Persist and reconstruct exactly as a new process would.
        let restored = try JSONDecoder().decode(ArchiveUploadSession.self, from: JSONEncoder().encode(checkpoint))
        let restarted = try backend(server)
        _ = try await restarted.resumeUpload(restored, from: source) { await saved.save($0) }
        XCTAssertEqual(server.uploadedParts, [1, 2, 2, 3])
        XCTAssertEqual(server.calls.filter { $0.httpMethod == "POST" && Server.query($0, "uploads") != nil }.count, 1)
    }

    func testCancellationPreservesDurablePartForResume() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        let saved = Checkpoints()
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { value in
                await saved.save(value)
                if value.acknowledgedBytes == Int64(Self.partBytes) { throw CancellationError() }
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let latest = await saved.last
        let checkpoint = try XCTUnwrap(latest)
        _ = try await b.resumeUpload(checkpoint, from: source) { await saved.save($0) }
        XCTAssertEqual(server.uploadedParts, [1, 2, 3])
    }

    func testCompletionErrorInsideHTTP200IsFailure() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        server.completionError = true
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source, checkpoint: { _ in })
            XCTFail("S3 can report a failed completion in an HTTP 200 response")
        } catch {}
        XCTAssertFalse(server.completed)
    }

    func testLostCompletionResponseRecoversWithoutUploadingPartsAgain() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        let saved = Checkpoints()
        server.loseCompletionResponseOnce = true
        do { _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { await saved.save($0) } }
        catch {}
        let latest = await saved.last
        let checkpoint = try XCTUnwrap(latest)
        let result = try await b.resumeUpload(checkpoint, from: source) { await saved.save($0) }
        XCTAssertEqual(server.uploadedParts, [1, 2, 3])
        let verification = try await b.verify(result.metadata, expected: integrity(data))
        XCTAssertTrue(verification.matches)
    }

    func testUnpersistedUploadIsAborted() async throws {
        let data = Data("fixture".utf8), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { _ in throw CancellationError() }
            XCTFail("Checkpoint failure must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(server.uploadedParts.isEmpty)
        XCTAssertEqual(server.calls.filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    func testBadPartChecksumNeverAcknowledged() async throws {
        let data = Data("fixture".utf8), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        server.corruptPartChecksum = true
        let saved = Checkpoints()
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source) { await saved.save($0) }
            XCTFail("Server part checksum mismatch must fail")
        } catch { XCTAssertEqual(error as? ArchiveBackendError, .invalidResponse) }
        let progress = await saved.progress
        XCTAssertEqual(progress, [0])
        XCTAssertFalse(server.completed)
    }

    func testExpiredUploadSignalsCoordinatorToRestart() async throws {
        let data = Data("fixture".utf8), server = Server(data: data), b = try backend(server), source = try file(data)
        defer { try? FileManager.default.removeItem(at: source) }
        server.expirePartUpload = true
        do {
            _ = try await b.resumeUpload(b.beginUpload(request(data)), from: source, checkpoint: { _ in })
            XCTFail("Expired upload must be reported")
        } catch { XCTAssertEqual(error as? ArchiveBackendError, .expiredUploadSession) }
        XCTAssertFalse(server.completed)
    }

    func testCorruptedMultipartHydrationDoesNotInstallShard() async throws {
        let data = fixture(), server = Server(data: data), b = try backend(server), source = try file(data)
        let target = source.appendingPathExtension("hydrated")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let uploaded = try await b.resumeUpload(b.beginUpload(request(data)), from: source, checkpoint: { _ in })
        let verified = try await b.verify(uploaded.metadata, expected: integrity(data))
        XCTAssertTrue(verified.matches)
        server.corruptDownload = true
        do {
            try await b.download(verified.metadata, to: target, progress: { _ in })
            XCTFail("Corrupt hydration must not install a shard")
        } catch { XCTAssertEqual(error as? ArchiveBackendError, .verificationMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testChangedLocalShardRejectedBeforeCreatingRemoteUpload() async throws {
        let original = Data("original".utf8), server = Server(data: original), b = try backend(server)
        let source = try file(Data("modified".utf8))
        defer { try? FileManager.default.removeItem(at: source) }
        let initial = try await b.beginUpload(request(original))
        do {
            _ = try await b.resumeUpload(initial, from: source, checkpoint: { _ in })
            XCTFail("Mutated shard must be rejected")
        } catch { XCTAssertEqual(error as? ArchiveBackendError, .localFileChanged) }
        XCTAssertTrue(server.calls.isEmpty)
    }
}
#endif
