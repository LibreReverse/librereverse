#if os(macOS)
import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func durableDownloadLock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// HTTP range downloads checkpoint directly to an app-owned file. No opaque
/// URLSession temporary file or bearer token needs to survive a process exit.
final class GoogleDriveDurableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let offset: Int64
    private let progress: @Sendable (Int64) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received: Int64
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var cancelled = false
    private var lastProgressAt: TimeInterval = 0

    private init(destination: URL, expectedBytes: Int64, offset: Int64,
                 progress: @escaping @Sendable (Int64) async -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.offset = offset
        received = offset
        self.progress = progress
    }

    static func run(request: URLRequest, remote: RemoteObjectMetadata, destination: URL,
                    configuration: URLSessionConfiguration,
                    progress: @escaping @Sendable (Int64) async -> Void) async throws -> HTTPURLResponse {
        let root = destination.deletingLastPathComponent().appendingPathComponent("DownloadCache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = [remote.identifier, remote.version ?? "", remote.sha256 ?? "", String(remote.byteCount)].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let partial = root.appendingPathComponent(key + ".partial")
        let descriptor = Darwin.open(root.appendingPathComponent(key + ".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while durableDownloadLock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        defer { _ = durableDownloadLock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        var count = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if count > remote.byteCount {
            try FileManager.default.removeItem(at: partial)
            count = 0
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        await progress(count)
        let response: HTTPURLResponse
        if count == remote.byteCount, count > 0 {
            response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        } else {
            var ranged = request
            if count > 0 { ranged.setValue("bytes=\(count)-", forHTTPHeaderField: "Range") }
            let delegate = GoogleDriveDurableDownload(destination: partial, expectedBytes: remote.byteCount,
                                                      offset: count, progress: progress)
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.start(request: ranged, configuration: configuration, continuation: continuation)
                }
            } onCancel: { delegate.cancel() }
        }
        guard (200..<300).contains(response.statusCode) else { return response }
        try Task.checkCancellation()
        let integrity = try ArchiveIntegrityEngine.hash(file: partial)
        guard integrity.byteCount == remote.byteCount else { throw URLError(.networkConnectionLost) }
        if let sha = remote.sha256, integrity.sha256.lowercased() != sha.lowercased() {
            try FileManager.default.removeItem(at: partial)
            throw ArchiveBackendError.verificationMismatch
        }
        try? FileManager.default.removeItem(at: destination)
        // Keep a hard link until canonical installation is committed. A crash
        // during resolver verification must not discard a completed transfer.
        try FileManager.default.linkItem(at: partial, to: destination)
        await progress(integrity.byteCount)
        return response
    }

    static func release(_ remote: RemoteObjectMetadata, temporaryURL: URL) {
        let root = temporaryURL.deletingLastPathComponent().appendingPathComponent("DownloadCache")
        let identity = [remote.identifier, remote.version ?? "", remote.sha256 ?? "", String(remote.byteCount)].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key + ".partial"))
    }

    private func start(request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            failure = ArchiveBackendError.invalidResponse
            completionHandler(.cancel)
            return
        }
        self.response = response
        guard (200..<300).contains(response.statusCode) else { completionHandler(.cancel); return }
        do {
            if response.statusCode == 206 {
                guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                      range.hasPrefix("bytes \(offset)-"), range.hasSuffix("/\(expectedBytes)") else {
                    throw ArchiveBackendError.invalidResponse
                }
            } else if response.statusCode != 200 {
                throw ArchiveBackendError.invalidResponse
            }
            let handle = try FileHandle(forWritingTo: destination)
            file = handle
            if response.statusCode == 200 {
                try handle.truncate(atOffset: 0)
                received = 0
            }
            try handle.seekToEnd()
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard let file else { throw CocoaError(.fileWriteUnknown) }
            try file.write(contentsOf: data)
            received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressAt >= 0.25 || received >= expectedBytes {
                lastProgressAt = now
                let total = received
                Task { await progress(total) }
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        file = nil
        let result: Result<HTTPURLResponse, Error>
        if let failure { result = .failure(failure) }
        else if let response, !(200..<300).contains(response.statusCode) { result = .success(response) }
        else if let error { result = .failure(error) }
        else if let response { result = .success(response) }
        else { result = .failure(ArchiveBackendError.invalidResponse) }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
#endif
