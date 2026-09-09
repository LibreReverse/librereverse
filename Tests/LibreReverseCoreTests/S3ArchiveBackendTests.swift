#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import LibreReverseCore

final class S3ArchiveBackendTests: XCTestCase {
    private let libraryID = "ABCD1234-1234-1234-1234-123456789ABC"
    private var key: ArchiveObjectKey { .init("libraries/\(libraryID)/video/example.mp4") }
    private func config(bucket: String = "test-bucket", region: String = "us-east-1") throws -> S3ArchiveConfiguration {
        try .init(endpoint: URL(string: "https://s3.example.test")!, bucket: bucket, region: region,
                  accessKey: "test-access", secretKey: "test-secret")
    }
    private final class Stub: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let h = Self.lock.withLock { Self.handler }
                let (status, headers, body) = try XCTUnwrap(h)(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock(); var requests: [URLRequest] = []
        func append(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var values: [URLRequest] { lock.withLock { requests } }
    }
    private func backend(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) throws -> S3ArchiveBackend {
        Stub.lock.withLock { Stub.handler = handler }
        let s = URLSessionConfiguration.ephemeral; s.protocolClasses = [Stub.self]
        return try .init(configuration: config(), libraryID: libraryID, session: URLSession(configuration: s))
    }
    private func integrity(_ data: Data) -> ArchiveIntegrity {
        .init(byteCount: Int64(data.count), sha256: S3SignatureV4.hex(SHA256.hash(data: data)))
    }
    private func uploadRequest(_ data: Data) -> ArchiveUploadRequest {
        .init(key: key, displayName: "fixture", videoID: 1, relativePath: "fixture", integrity: integrity(data))
    }
    private func headers(_ data: Data, checksum: Bool = true) -> [String: String] {
        var value = ["Content-Length": String(data.count), "ETag": "\"opaque-etag\""]
        if checksum { value["x-amz-checksum-sha256"] = Data(SHA256.hash(data: data)).base64EncodedString() }
        return value
    }
    func testProductionLibraryIdentifierAndMalformedScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibreReverseLibraryConfiguration(databaseURL: root.appendingPathComponent("library.sqlite3"),
            keyFileURL: root.appendingPathComponent("key"), mediaRoot: root.appendingPathComponent("Media"))
        try LibreReverseLibraryStore.initialize(library)
        let id = try LibreReverseArchiveStore.libraryUUID(configuration: library)
        XCTAssertEqual(id.utf8.count, 32)
        let b = try S3ArchiveBackend(configuration: config(), libraryID: id)
        let scoped = ArchiveObjectKey("libraries/\(id)/fixture")
        let request = ArchiveUploadRequest(key: scoped, displayName: "fixture", videoID: 1,
            relativePath: "fixture", integrity: integrity(Data()))
        let checkpoint = try await b.beginUpload(request)
        XCTAssertEqual(checkpoint.key, scoped)
        for bad in ["", "../escape", String(repeating: "g", count: 32), String(repeating: "é", count: 32),
                    "123456781234-1234-1234-1234-12345678"] {
            XCTAssertThrowsError(try S3ArchiveBackend(configuration: config(), libraryID: bad))
        }
    }

    func testAWSOfficialGetSigningVector() throws {
        // Published AWS example credentials, not real account credentials.
        let c = try S3ArchiveConfiguration(endpoint: URL(string: "https://examplebucket.s3.amazonaws.com")!,
            bucket: "examplebucket", accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        var r = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        r.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let signed = try S3SignatureV4.sign(r, configuration: c, payloadSHA256: S3SignatureV4.emptyHash, date: date)
        XCTAssertTrue(signed.value(forHTTPHeaderField: "Authorization")!.hasSuffix(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
    }
    func testCanonicalEncodingAndDuplicateQuerySorting() {
        XCTAssertEqual(S3SignatureV4.uriEncode("a b/+é//", preserveSlash: true), "a%20b/%2B%C3%A9//")
        XCTAssertEqual(S3SignatureV4.canonicalQuery([.init(name: "z", value: nil), .init(name: "a", value: "z"),
            .init(name: "a", value: " ")]), "a=%20&a=z&z=")
    }
    func testConfigurationIdentityAndDecodeValidation() throws {
        let a = try config(), changedCredentials = try S3ArchiveConfiguration(endpoint: URL(string: "https://S3.EXAMPLE.TEST:443/")!,
            bucket: a.bucket, accessKey: "rotated", secretKey: "rotated-secret")
        XCTAssertEqual(a.destinationIdentity, changedCredentials.destinationIdentity)
        XCTAssertNotEqual(a.destinationIdentity, try config(bucket: "other").destinationIdentity)
        XCTAssertNotEqual(a.destinationIdentity, try config(region: "eu-west-1").destinationIdentity)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        json["endpoint"] = "https://name:password@s3.example.test"
        XCTAssertThrowsError(try JSONDecoder().decode(S3ArchiveConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testBareEndpointDefaultsToHTTPS() throws {
        let bare = try S3ArchiveConfiguration(endpoint: URL(string: "s3.example.test")!,
            bucket: "test-bucket", accessKey: "test-access", secretKey: "test-secret")
        XCTAssertEqual(bare.endpoint.absoluteString, "https://s3.example.test")
        XCTAssertEqual(bare.destinationIdentity, try config().destinationIdentity)
        XCTAssertEqual(try S3ArchiveConfiguration.endpointURL("s3.example.test:9443/prefix/").absoluteString,
            "https://s3.example.test:9443/prefix")
        XCTAssertEqual(try S3ArchiveConfiguration.endpointURL("http://localhost:9000").absoluteString,
            "http://localhost:9000")
        for invalid in ["host name", "user:secret@host", "host?query=1", "host#fragment", "ftp://host", "http://remote.test"] {
            XCTAssertThrowsError(try S3ArchiveConfiguration.endpointURL(invalid))
        }
    }

    func testSignedUploadCheckpointAndFullServerChecksum() async throws {
        let data = Data("abc".utf8), calls = Calls(); let responseHeaders = headers(Data("abc".utf8))
        let b = try backend { r in
            calls.append(r); XCTAssertNotNil(r.value(forHTTPHeaderField: "Authorization"))
            if r.httpMethod == "PUT" {
                XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"), "*")
                XCTAssertEqual(r.value(forHTTPHeaderField: "x-amz-checksum-sha256"), Data(SHA256.hash(data: data)).base64EncodedString())
                XCTAssertNil(r.httpBody, "Upload must use a file-backed task, not a full in-memory body")
                return (200, [:], Data())
            }
            return (200, responseHeaders, Data())
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }; try data.write(to: file)
        let checkpoint = try await b.beginUpload(uploadRequest(data))
        XCTAssertEqual(checkpoint.acknowledgedBytes, 0)
        let saved = Calls()
        let result = try await b.resumeUpload(checkpoint, from: file) { value in
            XCTAssertEqual(value.acknowledgedBytes, 3); saved.append(URLRequest(url: file))
        }
        let verification = try await b.verify(result.metadata, expected: integrity(data))
        XCTAssertTrue(verification.matches); XCTAssertEqual(saved.values.count, 1)
        XCTAssertEqual(calls.values.map(\.httpMethod), ["PUT", "HEAD", "HEAD"])
    }
    func testMissingChecksumUsesDownloadedHashNotUserMetadataOrETag() async throws {
        let data = Data("abc".utf8), calls = Calls(); var h = headers(Data("abc".utf8), checksum: false)
        h["x-amz-meta-sha256"] = String(repeating: "0", count: 64)
        let b = try backend { r in calls.append(r); return (200, h, r.httpMethod == "GET" ? data : Data()) }
        let remote = try await b.locate(key)!
        XCTAssertNil(remote.sha256)
        let verification = try await b.verify(remote, expected: integrity(data))
        XCTAssertTrue(verification.matches); XCTAssertEqual(verification.metadata.sha256, integrity(data).sha256)
        XCTAssertEqual(calls.values.map(\.httpMethod), ["HEAD", "HEAD", "GET"])
        XCTAssertEqual(calls.values.last?.value(forHTTPHeaderField: "If-Match"), "\"opaque-etag\"")
    }
    func testMismatchedDownloadDoesNotInstallDestination() async throws {
        let good = Data("abc".utf8), bad = Data("xyz".utf8); let h = headers(good)
        let b = try backend { r in (200, h, r.httpMethod == "GET" ? bad : Data()) }
        let remote = try await b.locate(key)!
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try await b.download(remote, to: target, progress: { _ in }); XCTFail("must reject corruption") }
        catch { XCTAssertEqual(error as? ArchiveBackendError, .verificationMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testScopeAndSizeChecksBeforeNetwork() async throws {
        let b = try backend { _ in XCTFail("network must not run"); return (500, [:], Data()) }
        do { _ = try await b.locate(.init("libraries/another/video.mp4")); XCTFail("wrong scope") } catch {}
        let oversized = ArchiveUploadRequest(key: key, displayName: "large", videoID: 1, relativePath: "large",
            integrity: .init(byteCount: S3ArchiveBackend.maximumObjectBytes + 1, sha256: String(repeating: "0", count: 64)))
        do { _ = try await b.beginUpload(oversized); XCTFail("size limit") }
        catch { XCTAssertTrue(error is S3ArchiveError) }
        let initial = try await b.beginUpload(uploadRequest(Data("abc".utf8)))
        let other = try S3ArchiveBackend(configuration: config(bucket: "other"), libraryID: libraryID)
        do { _ = try await other.resumeUpload(initial, from: URL(fileURLWithPath: "/nonexistent"), checkpoint: { _ in }); XCTFail("scope") }
        catch { XCTAssertTrue(error is S3ArchiveError) }
    }
    func testSinglePutRetryVerifiesExistingObjectInsteadOfOverwriting() async throws {
        let data = Data("abc".utf8), h = headers(Data("abc".utf8))
        let b = try backend { r in (r.httpMethod == "PUT" ? 412 : 200, h, Data()) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }; try data.write(to: file)
        let initial = try await b.beginUpload(uploadRequest(data))
        let resumed = try await b.resumeUpload(initial, from: file, checkpoint: { _ in })
        XCTAssertEqual(resumed.metadata.sha256, integrity(data).sha256)
    }
    func testNamespaceRemovalRejectsForeignListEntry() async throws {
        let calls = Calls()
        let b = try backend { r in calls.append(r)
            if r.url!.query?.contains("uploads=") == true {
                return (200, [:], Data("<ListMultipartUploadsResult><IsTruncated>false</IsTruncated></ListMultipartUploadsResult>".utf8))
            }
            XCTAssertEqual(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "prefix" })?.value,
                           "librereverse/libraries/\(self.libraryID)/")
            return (200, [:], Data("<ListBucketResult><Contents><Key>unrelated/object</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        do { try await b.removeArchiveRoot(); XCTFail("must reject foreign object") } catch { XCTAssertTrue(error is S3ArchiveError) }
        XCTAssertEqual(calls.values.count, 2)
    }
    func testNamespaceRemovalPagesAndDeletesOnlyScopedKeys() async throws {
        let calls = Calls(), prefix = "librereverse/libraries/\(libraryID)/"
        let b = try backend { r in
            calls.append(r)
            if r.url!.query?.contains("uploads=") == true {
                return (200, [:], Data("<ListMultipartUploadsResult><IsTruncated>false</IsTruncated></ListMultipartUploadsResult>".utf8))
            }
            if r.httpMethod == "DELETE" { XCTAssertTrue(r.url!.path.contains(prefix)); return (204, [:], Data()) }
            let next = r.url!.query?.contains("continuation-token") == true
            let xml = "<ListBucketResult><Contents><Key>\(prefix)video/\(next ? "b" : "a")</Key></Contents><IsTruncated>\(next ? "false" : "true")</IsTruncated>\(next ? "" : "<NextContinuationToken>page 2</NextContinuationToken>")</ListBucketResult>"
            return (200, [:], Data(xml.utf8))
        }
        try await b.removeArchiveRoot()
        XCTAssertEqual(calls.values.map(\.httpMethod), ["GET", "GET", "DELETE", "GET", "DELETE"])
    }
    func testRootRemovalAbortsPaginatedIncompleteUploadsOnlyInLibrary() async throws {
        let calls = Calls(), prefix = "librereverse/libraries/\(libraryID)/"
        let b = try backend { r in
            calls.append(r)
            let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if r.httpMethod == "DELETE" {
                XCTAssertTrue(r.url!.path.contains(prefix))
                XCTAssertNotNil(query.first { $0.name == "uploadId" })
                return (204, [:], Data())
            }
            XCTAssertEqual(query.first { $0.name == "prefix" }?.value, prefix)
            if query.contains(where: { $0.name == "uploads" }) {
                let second = query.contains { $0.name == "key-marker" }
                if second {
                    XCTAssertEqual(query.first { $0.name == "key-marker" }?.value, prefix + "video/a")
                    XCTAssertEqual(query.first { $0.name == "upload-id-marker" }?.value, "upload+1")
                }
                let suffix = second ? "b" : "a"
                let marker = second ? "" : "<NextKeyMarker>\(prefix)video/a</NextKeyMarker><NextUploadIdMarker>upload+1</NextUploadIdMarker>"
                return (200, [:], Data("<ListMultipartUploadsResult><Upload><Key>\(prefix)video/\(suffix)</Key><UploadId>upload+\(suffix)</UploadId></Upload><IsTruncated>\(second ? "false" : "true")</IsTruncated>\(marker)</ListMultipartUploadsResult>".utf8))
            }
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        try await b.removeArchiveRoot()
        XCTAssertEqual(calls.values.map(\.httpMethod), ["GET", "DELETE", "GET", "DELETE", "GET"])
    }
    func testRootRemovalRejectsForeignIncompleteUploadBeforeDeletingAnything() async throws {
        let calls = Calls()
        let b = try backend { r in
            calls.append(r)
            return (200, [:], Data("<ListMultipartUploadsResult><Upload><Key>unrelated/object</Key><UploadId>foreign</UploadId></Upload><IsTruncated>false</IsTruncated></ListMultipartUploadsResult>".utf8))
        }
        do { try await b.removeArchiveRoot(); XCTFail("Must reject foreign multipart scope") }
        catch { XCTAssertTrue(error is S3ArchiveError) }
        XCTAssertEqual(calls.values.map(\.httpMethod), ["GET"])
    }
    func testErrorsDoNotEchoProviderSecrets() async throws {
        let b = try backend { _ in (403, [:], Data("sensitive echoed response".utf8)) }
        do { _ = try await b.locate(key); XCTFail("permission failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
    }
}
#endif
