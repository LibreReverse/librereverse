import Foundation

/// Bounded local diagnostics: no frames, OCR, transcripts or credentials.
public enum LibreReverseRecordingDiagnostics {
    public static func append(to directory: URL, event: String, operation: String,
        error: Error? = nil, at date: Date = Date(), maximumBytes: Int = 1_048_576) throws {
        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date),
            "event": event, "operation": operation,
        ]
        if let error {
            let nsError = error as NSError
            record["errorType"] = String(reflecting: type(of: error))
            record["errorDomain"] = nsError.domain
            record["errorCode"] = nsError.code
            record["description"] = String(describing: error)
        }
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0a)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording.jsonl")
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
            size.intValue + data.count > maximumBytes {
            let previous = directory.appendingPathComponent("recording.previous.jsonl")
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: url, to: previous)
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
