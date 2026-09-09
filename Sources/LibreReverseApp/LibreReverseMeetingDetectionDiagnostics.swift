import Foundation
import LibreReverseCore

/// Opt-in aggregate diagnostics. No window identifiers, application names,
/// titles, URLs, control labels, participant names, or recorded content.
enum LibreReverseMeetingDetectionDiagnostics {
    static let enabledDefaultsKey = "LibreReverse.meetingDetectionDiagnostics"

    struct Record: Codable {
        let timestamp: Date
        let phase: String
        let policy: String
        let lifecycle: String
        let counters: [String: Int]
    }

    static func lifecycleName(_ state: LibreReverseMeetingLifecycleState) -> String {
        switch state {
        case .idle: "idle"
        case .candidate: "candidate"
        case .prompt: "prompt"
        case .starting: "starting"
        case .recording: "recording"
        case .ending: "ending"
        case .stopping: "stopping"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    static func append(_ record: Record, to directory: URL, maximumBytes: Int = 1_048_576) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0a)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("meeting-detection.jsonl")
        if let size = try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue + data.count > maximumBytes {
            let previous = directory.appendingPathComponent("meeting-detection.previous.jsonl")
            if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
            try files.moveItem(at: url, to: previous)
        }
        if !files.fileExists(atPath: url.path) {
            guard files.createFile(atPath: url.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
