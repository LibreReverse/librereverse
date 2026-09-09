#if os(macOS)
import Foundation
import CryptoKit
import XCTest
@testable import LibreReverseCore

final class GoogleDriveArchiveBackendTests: XCTestCase {
    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []
        func append(_ value: Value) { lock.withLock { values.append(value) } }
        func snapshot() -> [Value] { lock.withLock { values } }
    }
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                Self.lock.lock()
                let handler = Self.handler
                Self.lock.unlock()
                let (status, headers, data) = try XCTUnwrap(handler)(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testResumableUploadUsesPrivateIdentityCheckpointsAndServerChecksumVerification() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let key = ArchiveObjectKey("video/0001/xid.mp4")
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let fileJSON = try JSONSerialization.data(withJSONObject: [
            "id": "drive-file-1",
            "size": "3",
            "sha256Checksum": sha,
            "version": "7",
            "trashed": false,
            "appProperties": ["librereverseObjectKey": key.value],
        ])
        let requests = Recorder<URLRequest>()
        let beginBodies = Recorder<Data>()
        StubProtocol.handler = { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let url = try XCTUnwrap(request.url)
            if url.absoluteString.contains("upload/drive/v3/files") {
                beginBodies.append(try Self.requestBody(request))
                return (200, ["Location": "https://upload.test/session-1"], Data())
            }
            if url.host == "upload.test" {
                if request.value(forHTTPHeaderField: "Content-Range") == "bytes */3" {
                    return (308, [:], Data())
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-2/3")
                XCTAssertEqual(try Self.requestBody(request), Data("abc".utf8))
                return (200, [:], fileJSON)
            }
            if url.path == "/drive/v3/files" {
                return (200, [:], Data(#"{"files":[]}"#.utf8))
            }
            if url.path.contains("/drive/v3/files/drive-file-1") {
                return (200, [:], fileJSON)
            }
            XCTFail("Unexpected request: \(url)")
            return (500, [:], Data())
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: session,
            uploadChunkSize: 256 * 1024,
            accessTokenProvider: { "test-token" }
        )
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("abc".utf8).write(to: local)
        let integrity = ArchiveIntegrity(byteCount: 3, sha256: sha)

        let located = try await backend.locate(key)
        XCTAssertNil(located)
        let upload = try await backend.beginUpload(.init(
            key: key,
            displayName: "xid.mp4",
            videoID: 1,
            relativePath: "xid.mp4",
            integrity: integrity
        ))
        let checkpoints = Recorder<Int64>()
        let result = try await backend.resumeUpload(upload, from: local) { checkpoint in
            checkpoints.append(checkpoint.acknowledgedBytes)
        }
        XCTAssertEqual(checkpoints.snapshot(), [3])
        let verification = try await backend.verify(result.metadata, expected: integrity)
        XCTAssertTrue(verification.matches)

        let begin = requests.snapshot().first {
            $0.url?.absoluteString.contains("upload/drive/v3/files") == true
        }
        _ = try XCTUnwrap(begin)
        let body = try XCTUnwrap(beginBodies.snapshot().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let properties = try XCTUnwrap(json["appProperties"] as? [String: String])
        XCTAssertEqual(properties["librereverseObjectKey"], key.value)
        XCTAssertEqual(properties["librereverseSHA256"], sha)
        XCTAssertTrue(properties.keys.allSatisfy { $0.hasPrefix("librereverse") })
        XCTAssertEqual(json["parents"] as? [String], ["root-folder"])
    }

    func testLocateRequiresMatchingObjectIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder", session: URLSession(configuration: configuration),
            accessTokenProvider: { "test-token" }
        )
        let key = ArchiveObjectKey("video/existing.mp4")
        defer { StubProtocol.handler = nil }
        do {
            let property = "librereverseObjectKey"
            StubProtocol.handler = { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                XCTAssertTrue(query.contains("key='librereverseObjectKey'"))
                let data = try JSONSerialization.data(withJSONObject: ["files": [[
                    "id": "existing", "size": "3", "sha256Checksum": "server-sha",
                    "appProperties": [property: key.value],
                ]]])
                return (200, [:], data)
            }
            let metadata = try await backend.locate(key)
            XCTAssertEqual(metadata?.identifier, "existing")
            XCTAssertEqual(metadata?.sha256, "server-sha")
        }
        StubProtocol.handler = { _ in
            let data = try JSONSerialization.data(withJSONObject: ["files": [[
                "id": "conflicting", "size": "3",
                "appProperties": ["librereverseObjectKey": "other"],
            ]]])
            return (200, [:], data)
        }
        do {
            _ = try await backend.locate(key)
            XCTFail("A mismatched identity must be rejected")
        } catch {
            XCTAssertEqual(error as? ArchiveBackendError, .invalidResponse)
        }
    }

    func testLocatorBudgetIncludesPropertyKeyAndFindsHashedBoundaryObjects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder", session: URLSession(configuration: configuration),
            accessTokenProvider: { "test-token" }
        )
        let bodies = Recorder<Data>()
        let queries = Recorder<String>()
        let budget = 124 - "librereverseObjectKey".utf8.count
        let longKey = String(repeating: "a", count: budget + 1)
        let expectedLocator = "sha256:" + SHA256.hash(data: Data(longKey.utf8)).map { String(format: "%02x", $0) }.joined()
        StubProtocol.handler = { request in
            if request.url?.host == "www.googleapis.com", request.httpMethod == "POST" {
                bodies.append(try Self.requestBody(request))
                return (200, ["Location": "https://upload.test/session"], Data())
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            queries.append(query)
            let data = try JSONSerialization.data(withJSONObject: ["files": [[
                "id": "boundary", "size": "3",
                "appProperties": ["librereverseObjectKey": expectedLocator],
            ]]])
            return (200, [:], data)
        }
        defer { StubProtocol.handler = nil }
        for value in [String(repeating: "a", count: budget), longKey, String(repeating: "é", count: budget)] {
            _ = try await backend.beginUpload(.init(
                key: ArchiveObjectKey(value), displayName: "file.mp4", videoID: 1,
                relativePath: "file.mp4", integrity: .init(byteCount: 3, sha256: String(repeating: "a", count: 64))
            ))
        }
        let properties = try bodies.snapshot().map { body -> [String: String] in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(object["appProperties"] as? [String: String])
        }
        XCTAssertEqual(properties[0]["librereverseObjectKey"], String(repeating: "a", count: budget))
        XCTAssertTrue(try XCTUnwrap(properties[1]["librereverseObjectKey"]).hasPrefix("sha256:"))
        XCTAssertTrue(try XCTUnwrap(properties[2]["librereverseObjectKey"]).hasPrefix("sha256:"))
        for propertySet in properties {
            XCTAssertTrue(propertySet.allSatisfy { $0.key.utf8.count + $0.value.utf8.count <= 124 })
        }
        let located = try await backend.locate(ArchiveObjectKey(longKey))
        XCTAssertEqual(located?.identifier, "boundary")
        let query = try XCTUnwrap(queries.snapshot().last)
        XCTAssertTrue(query.contains("key='librereverseObjectKey' and value='sha256:"))
    }

    func testLongShardKeyUsesDriveSafeDeterministicLocator() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let bodies = Recorder<Data>()
        StubProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/drive/v3/files", request.httpMethod == "GET" {
                return (200, [:], Data(#"{"files":[]}"#.utf8))
            }
            if url.path == "/drive/v3/files", request.httpMethod == "POST" {
                let body = try Self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if json["mimeType"] as? String == "application/vnd.google-apps.folder" {
                    return (200, [:], Data(#"{"id":"shards-folder","name":"Shards","parents":["root-folder"]}"#.utf8))
                }
            }
            bodies.append(try Self.requestBody(request))
            return (200, ["Location": "https://upload.test/shard"], Data())
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: session,
            accessTokenProvider: { "test-token" }
        )
        let key = ArchiveObjectKey(
            "libraries/0123456789abcdef0123456789abcdef/database-shard/"
            + String(repeating: "a", count: 96) + ".sqlite3"
        )
        _ = try await backend.beginUpload(.init(
            key: key,
            displayName: "period.sqlite3",
            objectKind: .databaseShard,
            subjectID: 9,
            relativePath: "Shards/period.sqlite3",
            contentType: "application/octet-stream",
            integrity: .init(byteCount: 3, sha256: String(repeating: "b", count: 64))
        ))
        let body = try XCTUnwrap(bodies.snapshot().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["parents"] as? [String], ["shards-folder"])
        let properties = try XCTUnwrap(json["appProperties"] as? [String: String])
        let locator = try XCTUnwrap(properties["librereverseObjectKey"])
        XCTAssertTrue(locator.hasPrefix("sha256:"))
        XCTAssertEqual(locator.lengthOfBytes(using: .utf8), 71)
        XCTAssertNotEqual(locator, key.value)
    }

    func testConcurrentUploadsCoalesceEachFolderCreation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let folderCreates = Recorder<String>()
        StubProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/drive/v3/files", request.httpMethod == "GET" {
                Thread.sleep(forTimeInterval: 0.03)
                return (200, [:], Data(#"{"files":[]}"#.utf8))
            }
            if url.path == "/drive/v3/files", request.httpMethod == "POST" {
                let body = try Self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if json["mimeType"] as? String == "application/vnd.google-apps.folder" {
                    let name = try XCTUnwrap(json["name"] as? String)
                    folderCreates.append(name)
                    let id = name == "202503" ? "month-folder" : "day-folder"
                    return (200, [:], Data("{\"id\":\"\(id)\"}".utf8))
                }
            }
            if url.path.contains("/upload/drive/v3/files") {
                let body = try Self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let name = try XCTUnwrap(json["name"] as? String)
                return (200, ["Location": "https://upload.test/\(name)"], Data())
            }
            XCTFail("Unexpected request: \(url)")
            return (500, [:], Data())
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: session,
            accessTokenProvider: { "test-token" }
        )
        let integrity = ArchiveIntegrity(
            byteCount: 3,
            sha256: String(repeating: "a", count: 64)
        )

        async let first = backend.beginUpload(.init(
            key: .init("video/1.mp4"),
            displayName: "one",
            videoID: 1,
            relativePath: "202503/21/one",
            integrity: integrity
        ))
        async let second = backend.beginUpload(.init(
            key: .init("video/2.mp4"),
            displayName: "two",
            videoID: 2,
            relativePath: "202503/21/two",
            integrity: integrity
        ))
        _ = try await (first, second)

        XCTAssertEqual(folderCreates.snapshot().sorted(), ["202503", "21"].sorted())
    }

    func testUnauthorizedResponseInvalidatesTokenAndRetriesExactlyOnce() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let authorizationHeaders = Recorder<String>()
        let invalidations = Recorder<Bool>()
        StubProtocol.handler = { request in
            authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if authorizationHeaders.snapshot().count == 1 {
                return (401, [:], Data(#"{"error":{"message":"expired"}}"#.utf8))
            }
            return (200, [:], Data(#"{"files":[]}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let tokens = Recorder<Int>()
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: session,
            accessTokenInvalidator: { invalidations.append(true) },
            accessTokenProvider: {
                tokens.append(1)
                return tokens.snapshot().count == 1 ? "stale-token" : "fresh-token"
            }
        )

        let located = try await backend.locate(.init("video/retry-auth.mp4"))
        XCTAssertNil(located)
        XCTAssertEqual(authorizationHeaders.snapshot(), [
            "Bearer stale-token",
            "Bearer fresh-token",
        ])
        XCTAssertEqual(invalidations.snapshot().count, 1)
    }

    func testRemoveIsAuthenticatedAndIdempotentWhenObjectIsAlreadyGone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let methods = Recorder<String>()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files/retired-file")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            methods.append(request.httpMethod ?? "")
            return methods.snapshot().count == 1
                ? (204, [:], Data())
                : (404, [:], Data())
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        let metadata = RemoteObjectMetadata(
            identifier: "retired-file",
            key: .init("database-shard/retired.sqlite3"),
            byteCount: 1,
            sha256: nil
        )

        try await backend.remove(metadata)
        try await backend.remove(metadata)

        XCTAssertEqual(methods.snapshot(), ["DELETE", "DELETE"])
    }

    func testCompleteResetDeletesAppOwnedArchiveRootIdempotently() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let methods = Recorder<String>()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files/root-folder")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            methods.append(request.httpMethod ?? "")
            return methods.snapshot().count == 1
                ? (204, [:], Data())
                : (404, [:], Data())
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )

        try await backend.removeArchiveRoot()
        try await backend.removeArchiveRoot()

        XCTAssertEqual(methods.snapshot(), ["DELETE", "DELETE"])
    }

    func testDownloadStreamsDeterminateByteProgressAndInstallsDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let bytes = Data(repeating: 0x5a, count: 32 * 1024)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.query, "alt=media")
            return (200, ["Content-Length": String(bytes.count)], bytes)
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let reported = Recorder<Int64>()

        try await backend.download(
            .init(
                identifier: "download-file",
                key: .init("video/download.mp4"),
                byteCount: Int64(bytes.count),
                sha256: nil
            ),
            to: destination
        ) { reported.append($0) }

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(reported.snapshot().last, Int64(bytes.count))
        XCTAssertTrue(reported.snapshot().allSatisfy {
            $0 >= 0 && $0 <= Int64(bytes.count)
        })
    }

    func testDownloadTimeoutIsExposedToCallerForRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let attempts = Recorder<Int>()
        StubProtocol.handler = { _ in
            attempts.append(1)
            throw URLError(.timedOut)
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await backend.download(
                .init(
                    identifier: "timed-out-file",
                    key: .init("video/timeout.mp4"),
                    byteCount: 1,
                    sha256: nil
                ),
                to: destination
            ) { _ in }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(attempts.snapshot().count, 3)
    }

    func testPartialChunkAcknowledgementRewindsToDriveConfirmedOffset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let requests = Recorder<(String, Data)>()
        StubProtocol.handler = { request in
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            if range == "bytes */3" { return (308, [:], Data()) }
            let body = try Self.requestBody(request)
            requests.append((range, body))
            if range == "bytes 0-2/3" {
                return (308, ["Range": "bytes=0-0"], Data())
            }
            XCTAssertEqual(range, "bytes 1-2/3")
            XCTAssertEqual(body, Data("bc".utf8))
            let result = try JSONSerialization.data(withJSONObject: [
                "id": "drive-file-partial",
                "size": "3",
                "sha256Checksum": "hash",
                "trashed": false,
                "appProperties": ["librereverseObjectKey": "video/partial.mp4"],
            ])
            return (200, [:], result)
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            uploadChunkSize: 256 * 1024,
            accessTokenProvider: { "token" }
        )
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("abc".utf8).write(to: local)
        let checkpoints = Recorder<Int64>()

        let result = try await backend.resumeUpload(
            .init(
                identifier: "https://upload.test/partial",
                key: .init("video/partial.mp4"),
                totalBytes: 3
            ),
            from: local
        ) { checkpoints.append($0.acknowledgedBytes) }

        XCTAssertEqual(result.metadata.identifier, "drive-file-partial")
        XCTAssertEqual(checkpoints.snapshot(), [1, 3])
        XCTAssertEqual(requests.snapshot().map(\.0), ["bytes 0-2/3", "bytes 1-2/3"])
    }

    func testDrive403RateLimitIsClassifiedAsRetryableProviderFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { _ in
            (403, [:], Data(#"{"error":{"message":"slow down","errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        do {
            _ = try await backend.locate(.init("video/rate-limited.mp4"))
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(
                error as? ArchiveBackendError,
                .rateLimited(status: 403, message: "slow down")
            )
        }
    }

    func testDrive403FindsRateLimitReasonAnywhereInProviderErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { _ in
            (403, [:], Data(#"{"error":{"message":"slow down","errors":[{"reason":"other"},{"reason":"rateLimitExceeded"}]}}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        do {
            _ = try await backend.locate(.init("video/rate-limited-after-other.mp4"))
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(
                error as? ArchiveBackendError,
                .rateLimited(status: 403, message: "slow down")
            )
        }
    }

    func testDuplicatePrivateObjectIdentityIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let key = ArchiveObjectKey("libraries/library/video/duplicate.mp4")
        let file: [String: Any] = [
            "id": "duplicate",
            "size": "1",
            "sha256Checksum": "00",
            "version": "1",
            "trashed": false,
            "appProperties": ["librereverseObjectKey": key.value],
        ]
        StubProtocol.handler = { _ in
            (200, [:], try JSONSerialization.data(withJSONObject: ["files": [file, file]]))
        }
        defer { StubProtocol.handler = nil }
        let backend = GoogleDriveArchiveBackend(
            rootFolderID: "root-folder",
            session: URLSession(configuration: configuration),
            accessTokenProvider: { "token" }
        )
        do {
            _ = try await backend.locate(key)
            XCTFail("Expected duplicate identity failure")
        } catch {
            XCTAssertEqual(error as? ArchiveBackendError, .duplicateObject(key))
        }
    }
}
#endif
