#if os(macOS)
import CryptoKit
import Foundation

/// Path-style S3 storage with durable multipart checkpoints for large objects.
public actor S3ArchiveBackend: ArchiveBackend {
    public nonisolated let kind: ArchiveBackendKind = .s3Compatible
    public static let maximumObjectBytes: Int64 = 5 * 1024 * 1024 * 1024 * 1024
    private let multipartThresholdBytes: Int64
    private let multipartPartBytes: Int64
    private let configuration: S3ArchiveConfiguration
    private let keyPrefix: String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let noRedirect = S3NoRedirectDelegate()

    private struct Identity: Codable {
        let destination: String
        let key: String
        var versionID: String?
    }
    private struct Part: Codable {
        let number: Int
        let bytes: Int64
        let etag: String
        let checksum: String
    }
    private struct Checkpoint: Codable {
        let destination: String
        let key: String
        let integrity: ArchiveIntegrity
        let contentType: String
        var uploadID: String?
        var partBytes: Int64?
        var parts: [Part]?
    }
    public init(configuration: S3ArchiveConfiguration, libraryID: String,
                session: URLSession = .shared,
                multipartThresholdBytes: Int64 = 64 * 1024 * 1024,
                multipartPartBytes: Int64 = 64 * 1024 * 1024,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard multipartThresholdBytes > 0, multipartThresholdBytes <= 5_000_000_000,
              multipartPartBytes >= 5 * 1024 * 1024, multipartPartBytes <= 5_000_000_000 else {
            throw S3ArchiveError.invalidConfiguration("Invalid multipart transfer size.")
        }
        self.multipartThresholdBytes = multipartThresholdBytes
        self.multipartPartBytes = multipartPartBytes
        let bytes = Array(libraryID.utf8)
        let isHex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        let compact = bytes.count == 32 && bytes.allSatisfy(isHex)
        let hyphenated = bytes.count == 36 && bytes.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == 45 : isHex(byte)
        }
        guard compact || hyphenated else { throw S3ArchiveError.invalidScope }
        self.configuration = configuration; self.keyPrefix = "libraries/\(libraryID)/"
        self.session = session; self.now = now
    }

    private func objectName(_ key: ArchiveObjectKey) throws -> String {
        guard key.value.hasPrefix(keyPrefix), key.value.count > keyPrefix.count,
              !key.value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !key.value.contains("\0"), key.value.utf8.count + "librereverse/".utf8.count <= 1024 else { throw S3ArchiveError.invalidScope }
        return "librereverse/" + key.value
    }
    private func token<T: Encodable>(_ value: T) throws -> String {
        "librereverse-s3-v1:" + (try JSONEncoder().encode(value)).base64EncodedString()
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let prefix = "librereverse-s3-v1:"
        guard value.hasPrefix(prefix), value.count < 8 * 1024 * 1024,
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))) else { throw S3ArchiveError.invalidCheckpoint }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw S3ArchiveError.invalidCheckpoint }
    }
    private func identity(_ remote: RemoteObjectMetadata) throws -> Identity {
        let value = try decode(Identity.self, remote.identifier)
        guard value.destination == configuration.destinationIdentity, value.key == remote.key.value else { throw S3ArchiveError.invalidScope }
        _ = try objectName(remote.key)
        return value
    }
    private func request(_ method: String, key: ArchiveObjectKey? = nil,
                         query: [URLQueryItem] = [], headers: [String: String] = [:],
                         hash: String = S3SignatureV4.emptyHash) throws -> URLRequest {
        var parts = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
        let name = try key.map(objectName)
        parts.percentEncodedPath = S3SignatureV4.uriEncode(parts.path + "/" + configuration.bucket
            + (name.map { "/" + $0 } ?? ""), preserveSlash: true)
        parts.percentEncodedQuery = query.isEmpty ? nil : S3SignatureV4.canonicalQuery(query)
        guard let url = parts.url else { throw ArchiveBackendError.invalidResponse }
        var value = URLRequest(url: url); value.httpMethod = method
        value.timeoutInterval = 120; value.cachePolicy = .reloadIgnoringLocalCacheData
        value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, header) in headers { value.setValue(header, forHTTPHeaderField: key) }
        return try S3SignatureV4.sign(value, configuration: configuration, payloadSHA256: hash, date: now())
    }
    private func response(_ value: URLResponse) throws -> HTTPURLResponse {
        guard let http = value as? HTTPURLResponse else { throw ArchiveBackendError.invalidResponse }
        return http
    }
    private func check(_ http: HTTPURLResponse, allowMissing: Bool = false) throws {
        guard !(200..<300).contains(http.statusCode), !(allowMissing && http.statusCode == 404) else { return }
        // Never surface provider response bodies, which may echo signed headers.
        if http.statusCode == 429 || http.statusCode == 503 {
            throw ArchiveBackendError.rateLimited(status: http.statusCode, message: "S3 is temporarily limiting requests.")
        }
        throw ArchiveBackendError.requestFailed(status: http.statusCode, message: "S3 request failed; check endpoint, region and bucket permissions.")
    }
    private func head(_ key: ArchiveObjectKey, versionID: String? = nil) async throws -> RemoteObjectMetadata? {
        let query = versionID.map { [URLQueryItem(name: "versionId", value: $0)] } ?? []
        let (_, raw) = try await session.data(for: request("HEAD", key: key, query: query,
            headers: ["x-amz-checksum-mode": "ENABLED"]), delegate: noRedirect)
        let http = try response(raw); try check(http, allowMissing: true)
        if http.statusCode == 404 { return nil }
        guard let text = http.value(forHTTPHeaderField: "Content-Length"), let count = Int64(text), count >= 0 else { throw ArchiveBackendError.invalidResponse }
        var sha: String?
        if http.value(forHTTPHeaderField: "x-amz-checksum-type") != "COMPOSITE",
           let checksum = http.value(forHTTPHeaderField: "x-amz-checksum-sha256"),
           let bytes = Data(base64Encoded: checksum), bytes.count == 32 { sha = S3SignatureV4.hex(bytes) }
        let version = http.value(forHTTPHeaderField: "x-amz-version-id")
        return RemoteObjectMetadata(identifier: try token(Identity(destination: configuration.destinationIdentity,
            key: key.value, versionID: version == "null" ? nil : version)),
            version: http.value(forHTTPHeaderField: "ETag"), key: key, byteCount: count, sha256: sha)
    }
    public func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata? { try await head(key) }

    public func beginUpload(_ value: ArchiveUploadRequest) async throws -> ArchiveUploadSession {
        _ = try objectName(value.key)
        guard value.integrity.byteCount >= 0 else { throw ArchiveBackendError.invalidResponse }
        guard value.integrity.byteCount <= Self.maximumObjectBytes else { throw S3ArchiveError.objectTooLarge }
        guard value.integrity.sha256.count == 64, value.integrity.sha256.allSatisfy({ $0.isHexDigit }),
              !value.contentType.contains("\n"), !value.contentType.contains("\r") else { throw ArchiveBackendError.invalidResponse }
        return ArchiveUploadSession(identifier: try token(Checkpoint(destination: configuration.destinationIdentity,
            key: value.key.value, integrity: value.integrity, contentType: value.contentType)), key: value.key, totalBytes: value.integrity.byteCount)
    }
    public func resumeUpload(_ initial: ArchiveUploadSession, from file: URL,
                             checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void) async throws -> ArchiveUploadResult {
        let saved = try decode(Checkpoint.self, initial.identifier)
        guard saved.destination == configuration.destinationIdentity, saved.key == initial.key.value,
              saved.integrity.byteCount == initial.totalBytes, initial.totalBytes >= 0,
              initial.acknowledgedBytes >= 0, initial.acknowledgedBytes <= initial.totalBytes else { throw S3ArchiveError.invalidCheckpoint }
        _ = try objectName(initial.key)
        guard initial.totalBytes <= Self.maximumObjectBytes else { throw S3ArchiveError.objectTooLarge }
        // Older single-PUT checkpoints may already acknowledge the whole file.
        if saved.uploadID == nil, initial.totalBytes >= multipartThresholdBytes,
           initial.acknowledgedBytes == initial.totalBytes {
            let local = try await Self.fileIntegrity(file)
            guard local == saved.integrity else { throw ArchiveBackendError.localFileChanged }
            guard let remote = try await head(initial.key) else { throw ArchiveBackendError.expiredUploadSession }
            guard try await verify(remote, expected: local).matches else { throw ArchiveBackendError.verificationMismatch }
            return .init(metadata: remote)
        }
        if initial.totalBytes >= multipartThresholdBytes || saved.uploadID != nil {
            return try await resumeMultipart(initial, saved: saved, from: file, checkpoint: checkpoint)
        }
        guard initial.acknowledgedBytes == 0 || initial.acknowledgedBytes == initial.totalBytes else {
            throw S3ArchiveError.invalidCheckpoint
        }
        let local = try await Self.fileIntegrity(file)
        guard local == saved.integrity else { throw ArchiveBackendError.localFileChanged }
        try Task.checkCancellation()
        let digest = Data(stride(from: 0, to: local.sha256.count, by: 2).map { index in
            UInt8(local.sha256.dropFirst(index).prefix(2), radix: 16)!
        }).base64EncodedString()
        let put = try request("PUT", key: initial.key,
            headers: ["Content-Type": saved.contentType, "Content-Length": String(local.byteCount),
                      "x-amz-checksum-sha256": digest, "If-None-Match": "*"], hash: local.sha256)
        let (_, raw) = try await session.upload(for: put, fromFile: file, delegate: noRedirect)
        let http = try response(raw)
        // A lost success response may leave a complete object behind. Never
        // overwrite it: independently verify the existing payload on retry.
        if http.statusCode != 412 { try check(http) }
        guard let remote = try await head(initial.key) else { throw ArchiveBackendError.invalidResponse }
        if http.statusCode == 412 {
            guard try await verify(remote, expected: local).matches else { throw ArchiveBackendError.verificationMismatch }
        }
        try await checkpoint(.init(identifier: initial.identifier, key: initial.key,
                                   acknowledgedBytes: initial.totalBytes, totalBytes: initial.totalBytes))
        return .init(metadata: remote)
    }

    /// SHA-256 multipart checksums are composite, so final archive verification
    /// still checks the complete downloaded payload rather than trusting ETags.
    /// https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html
    private func resumeMultipart(_ initial: ArchiveUploadSession, saved original: Checkpoint, from file: URL,
                                 checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void) async throws -> ArchiveUploadResult {
        var saved = original
        let local = try await Self.fileIntegrity(file)
        guard local == saved.integrity else { throw ArchiveBackendError.localFileChanged }
        let partBytes = saved.partBytes ?? max(multipartPartBytes, (initial.totalBytes + 9_999) / 10_000)
        var parts = saved.parts ?? []
        guard partBytes >= 5 * 1024 * 1024, partBytes <= 5_000_000_000, parts.count <= 10_000,
              (saved.uploadID == nil) == (saved.partBytes == nil),
              saved.uploadID != nil || parts.isEmpty else { throw S3ArchiveError.invalidCheckpoint }
        var acknowledged: Int64 = 0
        for (index, part) in parts.enumerated() {
            guard part.number == index + 1, acknowledged < initial.totalBytes,
                  part.bytes == min(partBytes, initial.totalBytes - acknowledged),
                  Self.validETag(part.etag),
                  Data(base64Encoded: part.checksum)?.count == 32 else { throw S3ArchiveError.invalidCheckpoint }
            acknowledged += part.bytes
        }
        guard acknowledged == initial.acknowledgedBytes else { throw S3ArchiveError.invalidCheckpoint }
        if let uploadID = saved.uploadID {
            guard !uploadID.isEmpty, uploadID.utf8.count <= 4096 else { throw S3ArchiveError.invalidCheckpoint }
            // Completion can succeed while its response is lost. A complete
            // manifest permits recovery without trying to create another object.
            if acknowledged == initial.totalBytes, let remote = try await head(initial.key) {
                guard try await verify(remote, expected: local).matches else { throw ArchiveBackendError.verificationMismatch }
                try? await abortMultipart(initial.key, uploadID: uploadID)
                return .init(metadata: remote)
            }
        } else {
            let (data, raw) = try await session.data(for: request("POST", key: initial.key,
                query: [.init(name: "uploads", value: "")],
                headers: ["Content-Type": saved.contentType, "x-amz-checksum-algorithm": "SHA256"]), delegate: noRedirect)
            try check(response(raw))
            let result = try S3MultipartResponse.parse(data, root: "InitiateMultipartUploadResult")
            guard let uploadID = result.values["UploadId"], !uploadID.isEmpty, uploadID.utf8.count <= 4096 else { throw ArchiveBackendError.invalidResponse }
            saved.uploadID = uploadID; saved.partBytes = partBytes; saved.parts = []
            do {
                try await checkpoint(.init(identifier: try token(saved), key: initial.key, totalBytes: initial.totalBytes))
            } catch {
                try? await abortMultipart(initial.key, uploadID: uploadID)
                throw error
            }
        }
        let uploadID = saved.uploadID!
        while acknowledged < initial.totalBytes {
            try Task.checkCancellation()
            let count = min(partBytes, initial.totalBytes - acknowledged)
            let piece = FileManager.default.temporaryDirectory.appendingPathComponent("s3-part-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: piece) }
            let integrity = try await Self.copyPart(from: file, offset: acknowledged, count: count, to: piece)
            let checksum = Self.base64Digest(integrity.sha256)
            let number = parts.count + 1
            guard number <= 10_000 else { throw S3ArchiveError.objectTooLarge }
            let (data, raw) = try await session.upload(for: request("PUT", key: initial.key,
                query: [.init(name: "partNumber", value: String(number)), .init(name: "uploadId", value: uploadID)],
                headers: ["Content-Length": String(count), "x-amz-checksum-sha256": checksum], hash: integrity.sha256),
                fromFile: piece, delegate: noRedirect)
            let http = try response(raw)
            if http.statusCode == 404 { throw ArchiveBackendError.expiredUploadSession }
            try check(http)
            guard data.count <= 1024 * 1024,
                  let etag = http.value(forHTTPHeaderField: "ETag"), Self.validETag(etag),
                  http.value(forHTTPHeaderField: "x-amz-checksum-sha256").map({ $0 == checksum }) ?? true else {
                throw ArchiveBackendError.invalidResponse
            }
            parts.append(.init(number: number, bytes: count, etag: etag, checksum: checksum))
            acknowledged += count; saved.parts = parts
            try await checkpoint(.init(identifier: try token(saved), key: initial.key,
                                       acknowledgedBytes: acknowledged, totalBytes: initial.totalBytes))
        }
        let manifest = "<CompleteMultipartUpload>" + parts.map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.xmlEscape($0.etag))</ETag><ChecksumSHA256>\($0.checksum)</ChecksumSHA256></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        let body = Data(manifest.utf8)
        var complete = try request("POST", key: initial.key, query: [.init(name: "uploadId", value: uploadID)],
            headers: ["Content-Type": "application/xml", "If-None-Match": "*"],
            hash: S3SignatureV4.hex(SHA256.hash(data: body)))
        complete.httpBody = body
        let (data, raw) = try await session.data(for: complete, delegate: noRedirect)
        let http = try response(raw)
        if [404, 409, 412].contains(http.statusCode) {
            if let remote = try await head(initial.key) {
                guard try await verify(remote, expected: local).matches else { throw ArchiveBackendError.verificationMismatch }
                try? await abortMultipart(initial.key, uploadID: uploadID)
                return .init(metadata: remote)
            }
            if http.statusCode == 409 { try? await abortMultipart(initial.key, uploadID: uploadID) }
            throw ArchiveBackendError.expiredUploadSession
        }
        try check(http)
        // S3 may return HTTP 200 with an embedded Error after sending keepalives.
        _ = try S3MultipartResponse.parse(data, root: "CompleteMultipartUploadResult")
        guard let remote = try await head(initial.key), remote.byteCount == initial.totalBytes else {
            throw ArchiveBackendError.invalidResponse
        }
        return .init(metadata: remote)
    }
    private func abortMultipart(_ key: ArchiveObjectKey, uploadID: String) async throws {
        let (_, raw) = try await session.data(for: request("DELETE", key: key,
            query: [.init(name: "uploadId", value: uploadID)]), delegate: noRedirect)
        try check(response(raw), allowMissing: true)
    }
    // Bound checkpoint growth even at the 10,000-part limit. Reject control
    // characters so JSON escaping cannot expand opaque ETags without bound.
    private static func validETag(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func base64Digest(_ hex: String) -> String {
        Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }).base64EncodedString()
    }
    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    /// One part on disk at a time; read/hash/copy uses a fixed 4 MiB buffer.
    private static func copyPart(from file: URL, offset: Int64, count: Int64, to target: URL) async throws -> ArchiveIntegrity {
        let work = Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: target.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(offset))
            var remaining = count, hash = SHA256()
            while remaining > 0 {
                try Task.checkCancellation()
                try autoreleasepool {
                    let bytes = try input.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))) ?? Data()
                    guard !bytes.isEmpty else { throw ArchiveBackendError.localFileChanged }
                    try output.write(contentsOf: bytes); hash.update(data: bytes); remaining -= Int64(bytes.count)
                }
            }
            return ArchiveIntegrity(byteCount: count, sha256: S3SignatureV4.hex(hash.finalize()))
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func fileIntegrity(_ file: URL) async throws -> ArchiveIntegrity {
        try await ArchiveIntegrityEngine.hashInBackground(file: file)
    }

    public func verify(_ remote: RemoteObjectMetadata, expected: ArchiveIntegrity) async throws -> RemoteVerification {
        let id = try identity(remote)
        guard let fresh = try await head(remote.key, versionID: id.versionID) else {
            return .init(metadata: remote, matches: false)
        }
        guard fresh.byteCount == expected.byteCount else { return .init(metadata: fresh, matches: false) }
        if let sha = fresh.sha256 { return .init(metadata: fresh, matches: sha == expected.sha256) }
        // User metadata and ETag are not full-file SHA-256 checksums. Providers
        // without a full checksum require a real streamed download and hash.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("s3-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        try await download(fresh, to: target, progress: { _ in })
        let actual = try await Self.fileIntegrity(target)
        let verified = RemoteObjectMetadata(identifier: fresh.identifier, version: fresh.version, key: fresh.key,
                                           byteCount: actual.byteCount, sha256: actual.sha256)
        return .init(metadata: verified, matches: actual == expected)
    }
    public func download(_ remote: RemoteObjectMetadata, to temporaryURL: URL,
                         progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let id = try identity(remote)
        let query = id.versionID.map { [URLQueryItem(name: "versionId", value: $0)] } ?? []
        let headers = remote.version.map { ["If-Match": $0] } ?? [:]
        await progress(0)
        let (downloaded, raw) = try await session.download(for: request("GET", key: remote.key, query: query, headers: headers), delegate: noRedirect)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try check(response(raw))
        let actual = try await Self.fileIntegrity(downloaded)
        guard actual.byteCount == remote.byteCount, remote.sha256 == nil || remote.sha256 == actual.sha256 else { throw ArchiveBackendError.verificationMismatch }
        try Task.checkCancellation()
        // Do not replace another caller's destination on a failed transfer.
        try FileManager.default.moveItem(at: downloaded, to: temporaryURL)
        await progress(actual.byteCount)
    }
    public func remove(_ remote: RemoteObjectMetadata) async throws {
        let id = try identity(remote)
        let query = id.versionID.map { [URLQueryItem(name: "versionId", value: $0)] } ?? []
        let headers = remote.version.map { ["If-Match": $0] } ?? [:]
        let (_, raw) = try await session.data(for: request("DELETE", key: remote.key, query: query, headers: headers), delegate: noRedirect)
        try check(response(raw), allowMissing: true)
    }
    public func validateConnection() async throws {
        let key = ArchiveObjectKey(keyPrefix + "connection-probe/" + UUID().uuidString)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let bytes = Data(UUID().uuidString.utf8); try bytes.write(to: local)
        let integrity = ArchiveIntegrity(byteCount: Int64(bytes.count), sha256: S3SignatureV4.hex(SHA256.hash(data: bytes)))
        let upload = try await beginUpload(.init(key: key, displayName: "connection-probe", objectKind: .databaseShard,
            subjectID: 0, relativePath: "connection-probe", contentType: "application/octet-stream", integrity: integrity))
        let remote = try await resumeUpload(upload, from: local, checkpoint: { _ in }).metadata
        do {
            let target = local.appendingPathExtension("download")
            defer { try? FileManager.default.removeItem(at: target) }
            try await download(.init(identifier: remote.identifier, version: remote.version, key: key,
                                    byteCount: integrity.byteCount, sha256: integrity.sha256), to: target, progress: { _ in })
        } catch { try? await remove(remote); throw error }
        try await remove(remote)
    }
    private func removeIncompleteUploads() async throws {
        var keyMarker: String?, uploadMarker: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "uploads", value: ""),
                         .init(name: "prefix", value: "librereverse/" + keyPrefix),
                         .init(name: "max-uploads", value: "1000")]
            if let keyMarker { query.append(.init(name: "key-marker", value: keyMarker)) }
            if let uploadMarker { query.append(.init(name: "upload-id-marker", value: uploadMarker)) }
            let (data, raw) = try await session.data(for: request("GET", query: query), delegate: noRedirect)
            try check(response(raw))
            let page = try S3MultipartListPage.parse(data)
            for (name, uploadID) in page.uploads {
                guard name.hasPrefix("librereverse/" + keyPrefix), !uploadID.isEmpty else { throw S3ArchiveError.invalidScope }
                let key = ArchiveObjectKey(String(name.dropFirst("librereverse/".count)))
                try await abortMultipart(key, uploadID: uploadID)
            }
            guard page.truncated else { return }
            guard let key = page.nextKey, !key.isEmpty, let upload = page.nextUpload,
                  seen.insert(key + "\0" + upload).inserted else { throw ArchiveBackendError.invalidResponse }
            keyMarker = key; uploadMarker = upload
        } while true
    }
    /// Removes only visible objects in this library's namespace. Bucket policy
    /// controls retained historical versions; unrelated objects are never listed.
    public func removeArchiveRoot() async throws {
        try await removeIncompleteUploads()
        var continuation: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "list-type", value: "2"),
                         URLQueryItem(name: "prefix", value: "librereverse/" + keyPrefix),
                         URLQueryItem(name: "max-keys", value: "1000")]
            if let continuation { query.append(.init(name: "continuation-token", value: continuation)) }
            let (data, raw) = try await session.data(for: request("GET", query: query), delegate: noRedirect)
            try check(response(raw)); guard data.count <= 4 * 1024 * 1024 else { throw ArchiveBackendError.invalidResponse }
            let page = try S3ListPage.parse(data)
            for name in page.keys {
                guard name.hasPrefix("librereverse/" + keyPrefix) else { throw S3ArchiveError.invalidScope }
                let key = ArchiveObjectKey(String(name.dropFirst("librereverse/".count)))
                _ = try objectName(key)
                let (_, raw) = try await session.data(for: request("DELETE", key: key), delegate: noRedirect)
                try check(response(raw), allowMissing: true)
            }
            continuation = page.truncated ? page.next : nil
            if page.truncated {
                guard let continuation, !continuation.isEmpty, seen.insert(continuation).inserted else { throw ArchiveBackendError.invalidResponse }
            }
        } while continuation != nil
    }
}

private final class S3NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class S3MultipartListPage: NSObject, XMLParserDelegate {
    var uploads: [(String, String)] = []
    var nextKey: String?, nextUpload: String?, truncated = false
    private var root: String?, text = "", key: String?, upload: String?
    private var sawTruncation = false, valid = true
    static func parse(_ data: Data) throws -> S3MultipartListPage {
        guard data.count <= 4 * 1024 * 1024 else { throw ArchiveBackendError.invalidResponse }
        let result = S3MultipartListPage(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), result.root == "ListMultipartUploadsResult", result.sawTruncation,
              result.valid, result.uploads.count <= 1000 else { throw ArchiveBackendError.invalidResponse }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if root == nil { root = elementName }; text = ""
        if elementName == "Upload" { key = nil; upload = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Key": key = text
        case "UploadId": upload = text
        case "NextKeyMarker": nextKey = text
        case "NextUploadIdMarker": nextUpload = text
        case "IsTruncated": sawTruncation = true; valid = valid && ["true", "false"].contains(text); truncated = text == "true"
        case "Upload":
            if let key, let upload { uploads.append((key, upload)) } else { valid = false }
        default: break
        }
        text = ""
    }
}
private final class S3MultipartResponse: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var root: String?, text = ""
    static func parse(_ data: Data, root: String) throws -> S3MultipartResponse {
        guard data.count <= 1024 * 1024 else { throw ArchiveBackendError.invalidResponse }
        let result = S3MultipartResponse(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), result.root == root else { throw ArchiveBackendError.invalidResponse }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if root == nil { root = elementName }; text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["UploadId", "ETag", "Code"].contains(elementName) { values[elementName] = text }
        text = ""
    }
}
private final class S3ListPage: NSObject, XMLParserDelegate {
    var keys: [String] = []; var next: String?; var truncated = false
    private var root: String?, text = ""
    private var sawTruncation = false, valid = true
    static func parse(_ data: Data) throws -> S3ListPage {
        let result = S3ListPage(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), result.root == "ListBucketResult", result.sawTruncation, result.valid, result.keys.count <= 1000 else { throw ArchiveBackendError.invalidResponse }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) { if root == nil { root = elementName }; text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Key" { keys.append(text) }
        if elementName == "NextContinuationToken" { next = text }
        if elementName == "IsTruncated" {
            sawTruncation = true; valid = valid && ["true", "false"].contains(text)
            truncated = text == "true"
        }
        text = ""
    }
}
#endif
