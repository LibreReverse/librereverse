#if os(macOS)
import CryptoKit
import Foundation

public actor GoogleDriveArchiveBackend: ArchiveBackend {
    public nonisolated let kind: ArchiveBackendKind = .googleDrive
    private let accessTokenProvider: @Sendable () async throws -> String
    private let accessTokenInvalidator: @Sendable () async -> Void
    private let rootFolderID: String
    private let session: URLSession
    private let uploadChunkSize: Int

    private struct DriveFile: Decodable {
        let id: String
        let name: String?
        let parents: [String]?
        let size: String?
        let sha256Checksum: String?
        let version: String?
        let trashed: Bool?
        let appProperties: [String: String]?
    }
    private struct DriveFileList: Decodable { let files: [DriveFile] }
    private var folderIDsByRelativePath: [String: String] = [:]
    private var folderResolutionTasks: [String: Task<String, Error>] = [:]

    public init(
        connection: GoogleDriveConnectionManager,
        rootFolderID: String,
        session: URLSession = .shared,
        uploadChunkSize: Int = 8 * 1024 * 1024
    ) {
        self.accessTokenProvider = { try await connection.validAccessToken() }
        self.accessTokenInvalidator = { await connection.invalidateAccessToken() }
        self.rootFolderID = rootFolderID
        self.session = session
        // Google requires resumable chunks to be multiples of 256 KiB.
        self.uploadChunkSize = max(256 * 1024, uploadChunkSize / (256 * 1024) * (256 * 1024))
    }

    init(
        rootFolderID: String,
        session: URLSession,
        uploadChunkSize: Int = 8 * 1024 * 1024,
        accessTokenInvalidator: @escaping @Sendable () async -> Void = {},
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.accessTokenInvalidator = accessTokenInvalidator
        self.rootFolderID = rootFolderID
        self.session = session
        self.uploadChunkSize = max(256 * 1024, uploadChunkSize / (256 * 1024) * (256 * 1024))
    }

    public func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: "trashed=false and \(GoogleDriveMetadata.query(.objectKey, equals: providerLocator(key)))"),
            .init(name: "spaces", value: "drive"),
            .init(name: "fields", value: "files(id,size,sha256Checksum,version,trashed,appProperties)"),
        ]
        let result: DriveFileList = try await jsonRequest(URLRequest(url: components.url!))
        if result.files.count > 1 { throw ArchiveBackendError.duplicateObject(key) }
        return try result.files.first.map { try metadata($0, expectedKey: key) }
    }

    public func beginUpload(_ request: ArchiveUploadRequest) async throws -> ArchiveUploadSession {
        let placement = try await placement(for: request.relativePath)
        var url = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        url.queryItems = [.init(name: "uploadType", value: "resumable"), .init(name: "fields", value: fields)]
        var http = URLRequest(url: url.url!)
        http.httpMethod = "POST"
        http.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        http.setValue(request.contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        http.setValue(String(request.integrity.byteCount), forHTTPHeaderField: "X-Upload-Content-Length")
        http.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": placement.name,
            "parents": [placement.parentID],
            "appProperties": [
                "librereverseObjectKey": providerLocator(request.key),
                "librereverseObjectKind": request.objectKind.rawValue,
                "librereverseSubjectID": String(request.subjectID),
                "librereverseVideo": request.objectKind == .video
                    ? String(request.subjectID) : "",
                "librereverseSHA256": request.integrity.sha256,
                "librereverseSchema": "1",
            ],
        ])
        let (_, response) = try await data(for: http)
        guard let location = response.value(forHTTPHeaderField: "Location"), URL(string: location) != nil else {
            throw ArchiveBackendError.invalidResponse
        }
        return ArchiveUploadSession(
            identifier: location,
            key: request.key,
            totalBytes: request.integrity.byteCount
        )
    }

    public func resumeUpload(
        _ initial: ArchiveUploadSession,
        from file: URL,
        checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void
    ) async throws -> ArchiveUploadResult {
        let actualSize = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
        guard actualSize == initial.totalBytes else { throw ArchiveBackendError.localFileChanged }
        guard let uploadURL = URL(string: initial.identifier) else { throw ArchiveBackendError.invalidResponse }
        var offset = try await acknowledgedOffset(uploadURL, total: initial.totalBytes)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while offset < initial.totalBytes {
            // A resumable server may acknowledge less than the body sent by
            // the preceding request. Always derive both the range and bytes
            // from its confirmed offset rather than the file handle's prior
            // read position.
            try handle.seek(toOffset: UInt64(offset))
            let length = min(Int64(uploadChunkSize), initial.totalBytes - offset)
            guard let bytes = try handle.read(upToCount: Int(length)), Int64(bytes.count) == length else {
                throw ArchiveBackendError.localFileChanged
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue(initial.key.value.hasSuffix(".mp4")
                ? "video/mp4" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            request.setValue("bytes \(offset)-\(offset + length - 1)/\(initial.totalBytes)", forHTTPHeaderField: "Content-Range")
            request.httpBody = bytes
            let (data, response) = try await authorizedData(for: request)
            if response.statusCode == 308 {
                let acknowledged = try acknowledgedBytes(response, missingRangeMeans: 0, total: initial.totalBytes)
                guard acknowledged > offset, acknowledged <= offset + length else {
                    throw ArchiveBackendError.invalidAcknowledgedRange
                }
                offset = acknowledged
                try await checkpoint(.init(identifier: initial.identifier, key: initial.key, acknowledgedBytes: offset, totalBytes: initial.totalBytes))
                continue
            }
            if response.statusCode == 404 || response.statusCode == 410 { throw ArchiveBackendError.expiredUploadSession }
            guard (200..<300).contains(response.statusCode) else { throw requestError(response.statusCode, data) }
            let driveFile = try JSONDecoder().decode(DriveFile.self, from: data)
            let result = try metadata(driveFile, expectedKey: initial.key)
            try await checkpoint(.init(identifier: initial.identifier, key: initial.key, acknowledgedBytes: initial.totalBytes, totalBytes: initial.totalBytes))
            return ArchiveUploadResult(metadata: result)
        }
        guard let existing = try await locate(initial.key) else { throw ArchiveBackendError.invalidResponse }
        return ArchiveUploadResult(metadata: existing)
    }

    public func verify(
        _ remote: RemoteObjectMetadata,
        expected: ArchiveIntegrity
    ) async throws -> RemoteVerification {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(remote.identifier)")!
        components.queryItems = [.init(name: "fields", value: fields)]
        let file: DriveFile = try await jsonRequest(URLRequest(url: components.url!))
        let fresh = try metadata(file, expectedKey: remote.key)
        return RemoteVerification(
            metadata: fresh,
            matches: !fresh.isTrashed
                && fresh.byteCount == expected.byteCount
                && fresh.sha256?.lowercased() == expected.sha256.lowercased()
        )
    }

    public func download(
        _ remote: RemoteObjectMetadata,
        to temporaryURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(remote.identifier)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        let request = URLRequest(url: components.url!)
        let response = try await authorizedDownload(
            for: request,
            remote: remote,
            to: temporaryURL,
            progress: progress
        )
        guard (200..<300).contains(response.statusCode) else { throw ArchiveBackendError.requestFailed(status: response.statusCode, message: "download failed") }
        let size = Int64(try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        await progress(size)
    }

    public func releaseDownloadedCopy(_ remote: RemoteObjectMetadata, temporaryURL: URL) async {
        GoogleDriveDurableDownload.release(remote, temporaryURL: temporaryURL)
    }

    public func remove(_ remote: RemoteObjectMetadata) async throws {
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(remote.identifier)")!
        )
        request.httpMethod = "DELETE"
        let (data, response) = try await authorizedData(for: request)
        // Deletion is idempotent: a prior cleanup attempt may have succeeded
        // even when its response was lost.
        guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else {
            throw requestError(response.statusCode, data)
        }
    }

    /// Removes the app-owned archive root and every object below it. This is
    /// intentionally separate from per-object deletion: a user-authorized
    /// full-library reset must also remove objects that an older local catalog
    /// can no longer enumerate.
    public func removeArchiveRoot() async throws {
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(rootFolderID)")!
        )
        request.httpMethod = "DELETE"
        let (data, response) = try await authorizedData(for: request)
        guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else {
            throw requestError(response.statusCode, data)
        }
        folderIDsByRelativePath.removeAll()
        folderResolutionTasks.removeAll()
    }

    private func placement(for relativePath: String) async throws -> (parentID: String, name: String) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let name = parts.last else {
            throw ArchiveBackendError.invalidResponse
        }
        var parentID = rootFolderID
        var accumulated: [String] = []
        for component in parts.dropLast() {
            accumulated.append(component)
            let key = accumulated.joined(separator: "/")
            if let cached = folderIDsByRelativePath[key] {
                parentID = cached
                continue
            }
            parentID = try await coalescedFolder(
                named: component,
                under: parentID,
                relativePath: key
            )
            folderIDsByRelativePath[key] = parentID
        }
        return (parentID, name)
    }

    private func coalescedFolder(
        named name: String,
        under parentID: String,
        relativePath: String
    ) async throws -> String {
        if let cached = folderIDsByRelativePath[relativePath] { return cached }
        if let pending = folderResolutionTasks[relativePath] {
            return try await pending.value
        }
        let task = Task { [self] in
            try await resolveFolder(named: name, under: parentID, relativePath: relativePath)
        }
        folderResolutionTasks[relativePath] = task
        do {
            let folderID = try await task.value
            folderIDsByRelativePath[relativePath] = folderID
            folderResolutionTasks[relativePath] = nil
            return folderID
        } catch {
            folderResolutionTasks[relativePath] = nil
            throw error
        }
    }

    private func resolveFolder(named name: String, under parentID: String, relativePath: String) async throws -> String {
        var listURL = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        listURL.queryItems = [
            .init(name: "q", value: "trashed=false and mimeType='application/vnd.google-apps.folder' and name='\(escapeQuery(name))' and '\(escapeQuery(parentID))' in parents"),
            .init(name: "spaces", value: "drive"),
            .init(name: "fields", value: "files(id,name,parents)"),
        ]
        let existing: DriveFileList = try await jsonRequest(URLRequest(url: listURL.url!))
        if existing.files.count > 1 { throw ArchiveBackendError.invalidResponse }
        if let id = existing.files.first?.id { return id }

        var createURL = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        createURL.queryItems = [.init(name: "fields", value: "id,name,parents")]
        var request = URLRequest(url: createURL.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentID],
            "appProperties": [
                "librereverseSchema": "1",
            ],
        ])
        let created: DriveFile = try await jsonRequest(request)
        return created.id
    }

    private var fields: String { "id,name,parents,size,sha256Checksum,version,trashed,appProperties" }

    private func acknowledgedOffset(_ url: URL, total: Int64) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (data, response) = try await authorizedData(for: request)
        if response.statusCode == 308 {
            return try acknowledgedBytes(response, missingRangeMeans: 0, total: total)
        }
        if response.statusCode == 404 || response.statusCode == 410 { throw ArchiveBackendError.expiredUploadSession }
        if (200..<300).contains(response.statusCode) { return total }
        throw requestError(response.statusCode, data)
    }

    private func acknowledgedBytes(
        _ response: HTTPURLResponse,
        missingRangeMeans fallback: Int64,
        total: Int64
    ) throws -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return fallback }
        guard range.hasPrefix("bytes=0-"),
              let last = range.dropFirst("bytes=0-".count).wholeNumber,
              last >= 0,
              last < total else {
            throw ArchiveBackendError.invalidAcknowledgedRange
        }
        return last + 1
    }

    private func metadata(_ file: DriveFile, expectedKey: ArchiveObjectKey) throws -> RemoteObjectMetadata {
        guard GoogleDriveMetadata.value(.objectKey, in: file.appProperties) == providerLocator(expectedKey) else {
            throw ArchiveBackendError.invalidResponse
        }
        return RemoteObjectMetadata(
            identifier: file.id,
            version: file.version,
            key: expectedKey,
            byteCount: file.size.flatMap(Int64.init) ?? 0,
            sha256: file.sha256Checksum,
            isTrashed: file.trashed ?? false
        )
    }

    private func jsonRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await data(for: request)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ArchiveBackendError.invalidResponse }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await authorizedData(for: request)
        guard (200..<300).contains(response.statusCode) else { throw requestError(response.statusCode, data) }
        return (data, response)
    }

    private func authorizedData(for baseRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            var request = baseRequest
            let token = try await accessTokenProvider()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, raw) = try await session.data(for: request)
            guard let response = raw as? HTTPURLResponse else { throw ArchiveBackendError.invalidResponse }
            if response.statusCode == 401, attempt == 0 {
                await accessTokenInvalidator()
                continue
            }
            return (data, response)
        }
        throw ArchiveBackendError.invalidResponse
    }

    private func authorizedDownload(
        for baseRequest: URLRequest,
        remote: RemoteObjectMetadata,
        to destination: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> HTTPURLResponse {
        for attempt in 0...1 {
            var request = baseRequest
            let token = try await accessTokenProvider()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var response: HTTPURLResponse?
            for networkAttempt in 0..<3 {
                do {
                    response = try await GoogleDriveDurableDownload.run(
                        request: request,
                        remote: remote,
                        destination: destination,
                        configuration: session.configuration,
                        progress: progress
                    )
                    break
                } catch {
                    guard networkAttempt < 2, Self.isRetryableDownloadError(error) else { throw error }
                    // The next attempt resumes from the persisted byte count,
                    // including after a process restart or token refresh.
                    try await Task.sleep(
                        nanoseconds: UInt64(networkAttempt + 1) * 500_000_000
                    )
                }
            }
            guard let response else { throw ArchiveBackendError.invalidResponse }
            if response.statusCode == 401, attempt == 0 {
                try? FileManager.default.removeItem(at: destination)
                await accessTokenInvalidator()
                continue
            }
            return response
        }
        throw ArchiveBackendError.invalidResponse
    }

    private nonisolated static func isRetryableDownloadError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
            .resourceUnavailable,
        ].contains(urlError.code)
    }

    private func requestError(_ status: Int, _ data: Data) -> ArchiveBackendError {
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = payload.flatMap { $0["error"] as? [String: Any] }
        let message = error?["message"] as? String ?? "unknown provider error"
        let reasons = (error?["errors"] as? [[String: Any]])?
            .compactMap { $0["reason"] as? String } ?? []
        let rateLimitReasons = [
            "rateLimitExceeded", "userRateLimitExceeded", "sharingRateLimitExceeded",
        ]
        if status == 429 || (status == 403 && reasons.contains(where: rateLimitReasons.contains)) {
            return .rateLimited(status: status, message: message)
        }
        return .requestFailed(status: status, message: message)
    }

    private func escapeQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// Drive's 124-byte property limit includes the UTF-8 key and value.
    /// https://developers.google.com/workspace/drive/api/guides/properties
    private func providerLocator(_ key: ArchiveObjectKey) -> String {
        let budget = 124 - GoogleDriveMetadata.Key.objectKey.rawValue.utf8.count
        return locator(key, valueBudget: budget)
    }

    private func locator(_ key: ArchiveObjectKey, valueBudget: Int) -> String {
        guard key.value.utf8.count > valueBudget else { return key.value }
        let digest = SHA256.hash(data: Data(key.value.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

}

private extension Substring {
    var wholeNumber: Int64? {
        guard !isEmpty, allSatisfy(\.isNumber) else { return nil }
        return Int64(self)
    }
}
#endif
