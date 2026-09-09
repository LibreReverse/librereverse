#if os(macOS)
import CryptoKit
import Foundation

public struct ArchiveObjectKey: Hashable, Codable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

public struct ArchiveIntegrity: Equatable, Codable, Sendable {
    public let byteCount: Int64
    public let sha256: String
    public init(byteCount: Int64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
    }
}

public struct ArchiveUploadRequest: Equatable, Sendable {
    public enum ObjectKind: String, Equatable, Sendable {
        case video
        case databaseShard = "database_shard"
    }

    public let key: ArchiveObjectKey
    public let displayName: String
    public let objectKind: ObjectKind
    public let subjectID: Int64
    public let relativePath: String
    public let contentType: String
    public let integrity: ArchiveIntegrity

    /// Compatibility projection for the existing video archive pipeline.
    /// Callers archiving a shard must use `subjectID` and `objectKind`.
    public var videoID: Int64 { subjectID }

    public init(
        key: ArchiveObjectKey,
        displayName: String,
        videoID: Int64,
        relativePath: String,
        integrity: ArchiveIntegrity
    ) {
        self.key = key
        self.displayName = displayName
        self.objectKind = .video
        self.subjectID = videoID
        self.relativePath = relativePath
        self.contentType = "video/mp4"
        self.integrity = integrity
    }

    public init(
        key: ArchiveObjectKey,
        displayName: String,
        objectKind: ObjectKind,
        subjectID: Int64,
        relativePath: String,
        contentType: String,
        integrity: ArchiveIntegrity
    ) {
        self.key = key
        self.displayName = displayName
        self.objectKind = objectKind
        self.subjectID = subjectID
        self.relativePath = relativePath
        self.contentType = contentType
        self.integrity = integrity
    }
}

public struct ArchiveUploadSession: Equatable, Codable, Sendable {
    public let identifier: String
    public let key: ArchiveObjectKey
    public let acknowledgedBytes: Int64
    public let totalBytes: Int64

    public init(identifier: String, key: ArchiveObjectKey, acknowledgedBytes: Int64 = 0, totalBytes: Int64) {
        self.identifier = identifier
        self.key = key
        self.acknowledgedBytes = acknowledgedBytes
        self.totalBytes = totalBytes
    }
}

public struct RemoteObjectMetadata: Equatable, Codable, Sendable {
    public let identifier: String
    public let version: String?
    public let key: ArchiveObjectKey
    public let byteCount: Int64
    public let sha256: String?
    public let isTrashed: Bool

    public init(
        identifier: String,
        version: String? = nil,
        key: ArchiveObjectKey,
        byteCount: Int64,
        sha256: String?,
        isTrashed: Bool = false
    ) {
        self.identifier = identifier
        self.version = version
        self.key = key
        self.byteCount = byteCount
        self.sha256 = sha256?.lowercased()
        self.isTrashed = isTrashed
    }
}

public struct ArchiveUploadResult: Equatable, Sendable {
    public let metadata: RemoteObjectMetadata
    public init(metadata: RemoteObjectMetadata) { self.metadata = metadata }
}

public struct RemoteVerification: Equatable, Sendable {
    public let metadata: RemoteObjectMetadata
    public let matches: Bool
    public init(metadata: RemoteObjectMetadata, matches: Bool) {
        self.metadata = metadata
        self.matches = matches
    }
}

public protocol ArchiveBackend: Sendable {
    var kind: ArchiveBackendKind { get }
    func locate(_ key: ArchiveObjectKey) async throws -> RemoteObjectMetadata?
    func beginUpload(_ request: ArchiveUploadRequest) async throws -> ArchiveUploadSession
    func resumeUpload(
        _ session: ArchiveUploadSession,
        from file: URL,
        checkpoint: @Sendable (ArchiveUploadSession) async throws -> Void
    ) async throws -> ArchiveUploadResult
    func verify(
        _ metadata: RemoteObjectMetadata,
        expected: ArchiveIntegrity
    ) async throws -> RemoteVerification
    func download(
        _ metadata: RemoteObjectMetadata,
        to temporaryURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
    func remove(_ metadata: RemoteObjectMetadata) async throws
    func removeArchiveRoot() async throws
    func releaseDownloadedCopy(_ metadata: RemoteObjectMetadata, temporaryURL: URL) async
}

public extension ArchiveBackend {
    func removeArchiveRoot() async throws {
        throw ArchiveBackendError.unsupportedOperation("archive root deletion")
    }
    func releaseDownloadedCopy(_ metadata: RemoteObjectMetadata, temporaryURL: URL) async {}
    func remove(_ metadata: RemoteObjectMetadata) async throws {
        throw ArchiveBackendError.unsupportedOperation("remote object deletion")
    }
}

public enum ArchiveIntegrityEngine {
    /// Runs bulk file IO off the caller's executor and stops between blocks
    /// when an archive worker is retired during a provider switch.
    public static func hashInBackground(file url: URL) async throws -> ArchiveIntegrity {
        try Task.checkCancellation()
        let work = Task.detached(priority: .utility) {
            try hash(file: url, checkCancellation: true)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Streams fixed-size blocks; video bytes are never loaded wholesale.
    public static func hash(
        file url: URL,
        chunkSize: Int = 4 * 1024 * 1024,
        checkCancellation: Bool = false
    ) throws -> ArchiveIntegrity {
        guard chunkSize > 0 else { throw CocoaError(.fileReadUnknown) }
        if checkCancellation { try Task.checkCancellation() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while true {
            if checkCancellation { try Task.checkCancellation() }
            // FileHandle bridges autoreleased NSData on macOS. Drain each block
            // so a long hash does not retain every read until the task returns.
            let hasBytes = try autoreleasepool {
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { return false }
                hasher.update(data: data)
                count += Int64(data.count)
                return true
            }
            if !hasBytes { break }
        }
        return ArchiveIntegrity(
            byteCount: count,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}

public enum ArchiveBackendError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case requestFailed(status: Int, message: String)
    case rateLimited(status: Int, message: String)
    case duplicateObject(ArchiveObjectKey)
    case expiredUploadSession
    case invalidAcknowledgedRange
    case localFileChanged
    case verificationMismatch
    case unsupportedOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Archive provider returned an invalid response."
        case let .requestFailed(status, message): "Archive provider request failed (HTTP \(status)): \(message)"
        case let .rateLimited(status, message): "Archive provider is rate limiting requests (HTTP \(status)): \(message)"
        case let .duplicateObject(key): "Multiple remote objects exist for \(key.value)."
        case .expiredUploadSession: "The resumable upload session expired and must be restarted."
        case .invalidAcknowledgedRange: "The provider returned an invalid upload checkpoint."
        case .localFileChanged: "The finalized local video changed while it was being archived."
        case .verificationMismatch: "The remote file did not match the local video."
        case let .unsupportedOperation(operation): "Archive provider does not support \(operation)."
        }
    }
}
#endif
