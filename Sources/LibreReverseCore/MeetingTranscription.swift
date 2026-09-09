#if os(macOS)
@preconcurrency import AVFoundation
import CryptoKit
import Foundation

public struct MeetingTranscriptionWord: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let probability: Double?
    public let fullTextUTF16Offset: Int

    public init(
        text: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        probability: Double? = nil,
        fullTextUTF16Offset: Int
    ) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.probability = probability
        self.fullTextUTF16Offset = fullTextUTF16Offset
    }
}

public struct MeetingTranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let language: String?
    public let words: [MeetingTranscriptionWord]

    public init(text: String, language: String?, words: [MeetingTranscriptionWord]) {
        self.text = text
        self.language = language
        self.words = words
    }
}

public protocol MeetingTranscriber: Sendable {
    func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult
}

public struct MeetingTranscriptionCheckpointContext: Equatable, Sendable {
    public let identifier: String
    public let url: URL
    public let encryptionKeyURL: URL

    public init(identifier: String, url: URL, encryptionKeyURL: URL) {
        self.identifier = identifier
        self.url = url
        self.encryptionKeyURL = encryptionKeyURL
    }
}

public protocol CheckpointingMeetingTranscriber: MeetingTranscriber {
    func transcribe(
        mediaURL: URL,
        checkpoint: MeetingTranscriptionCheckpointContext
    ) async throws -> MeetingTranscriptionResult
}

public enum MeetingTranscriptionError: Error, Equatable {
    case invalidJSON(String)
    case invalidWordTiming
    case wordMissingFromTranscript(String)
    case processFailed(status: Int32, message: String)
    case outputMissing(URL)
    case invalidLegacyClock(Int)
    case missingAudioTrack(URL)
    case audioExtractionFailed(String)
    case invalidWindowingConfiguration(windowSeconds: TimeInterval, overlapSeconds: TimeInterval)
    case invalidCheckpoint(String)
}

public struct MeetingTranscriptionWindowingConfiguration: Equatable, Sendable {
    public let windowSeconds: TimeInterval
    public let overlapSeconds: TimeInterval

    /// Five-minute inference windows bound decoded PCM to roughly 18.4 MiB at
    /// 16 kHz mono Float32 while avoiding a model launch for every live-sized
    /// 30-second chunk. The five-second overlap retains boundary context.
    public static let production = Self(windowSeconds: 5 * 60, overlapSeconds: 5)

    public init(windowSeconds: TimeInterval, overlapSeconds: TimeInterval) {
        self.windowSeconds = windowSeconds
        self.overlapSeconds = overlapSeconds
    }
}

internal struct MeetingTranscriptionWindow: Equatable, Sendable {
    let index: Int
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let replaceFromSeconds: TimeInterval
    let finalizeThroughSeconds: TimeInterval
}

internal enum MeetingTranscriptionWindowPlan {
    static func make(
        mediaDurationSeconds: TimeInterval,
        configuration: MeetingTranscriptionWindowingConfiguration
    ) throws -> [MeetingTranscriptionWindow] {
        guard configuration.windowSeconds > 0,
            configuration.overlapSeconds >= 0,
            configuration.overlapSeconds < configuration.windowSeconds
        else {
            throw MeetingTranscriptionError.invalidWindowingConfiguration(
                windowSeconds: configuration.windowSeconds,
                overlapSeconds: configuration.overlapSeconds
            )
        }
        guard mediaDurationSeconds.isFinite, mediaDurationSeconds > 0 else { return [] }

        let stride = configuration.windowSeconds - configuration.overlapSeconds
        var windows: [MeetingTranscriptionWindow] = []
        var start: TimeInterval = 0
        while start < mediaDurationSeconds {
            let duration = min(configuration.windowSeconds, mediaDurationSeconds - start)
            windows.append(
                .init(
                    index: windows.count,
                    startSeconds: start,
                    durationSeconds: duration,
                    replaceFromSeconds: start,
                    finalizeThroughSeconds: min(mediaDurationSeconds, start + stride)
                ))
            if start + duration >= mediaDurationSeconds { break }
            start += stride
        }
        return windows
    }
}

/// Decoder for whisper.cpp's `--output-json-full` result. Whisper.cpp exposes
/// timestamped decoder tokens, so adjacent subword and punctuation tokens
/// are folded into words.
public enum WhisperCPPJSONTranscriptDecoder {
    private struct Payload: Decodable {
        let result: Result
        let transcription: [Segment]
    }

    private struct Result: Decodable { let language: String? }
    private struct Segment: Decodable {
        let text: String
        let tokens: [Token]?
    }
    private struct Token: Decodable {
        let text: String
        let offsets: Offsets?
        let p: Double?
    }
    private struct Offsets: Decodable {
        let from: Int64
        let to: Int64
    }

    private struct PendingWord {
        var text: String
        var start: Double
        var end: Double
        var probabilityTotal: Double
        var probabilityCount: Int
    }

    public static func decode(_ data: Data) throws -> MeetingTranscriptionResult {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MeetingTranscriptionError.invalidJSON(error.localizedDescription)
        }
        let transcript = payload.transcription
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = transcript as NSString
        var searchLocation = 0
        var pending: PendingWord?
        var words: [MeetingTranscriptionWord] = []

        func append(_ pending: PendingWord?) throws {
            guard let pending, !pending.text.isEmpty else { return }
            let range = NSRange(
                location: min(searchLocation, searchable.length),
                length: max(0, searchable.length - min(searchLocation, searchable.length))
            )
            let match = searchable.range(of: pending.text, options: [], range: range)
            guard match.location != NSNotFound else {
                throw MeetingTranscriptionError.wordMissingFromTranscript(pending.text)
            }
            words.append(
                .init(
                    text: pending.text,
                    startSeconds: pending.start,
                    endSeconds: pending.end,
                    probability: pending.probabilityCount == 0
                        ? nil
                        : pending.probabilityTotal / Double(pending.probabilityCount),
                    fullTextUTF16Offset: match.location
                ))
            searchLocation = match.location + match.length
        }

        for token in payload.transcription.flatMap({ $0.tokens ?? [] }) {
            guard let offsets = token.offsets, offsets.from >= 0, offsets.to >= offsets.from else {
                continue
            }
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("[") else { continue }
            let beginsWord = token.text.first?.isWhitespace == true
            if beginsWord {
                try append(pending)
                pending = .init(
                    text: trimmed,
                    start: Double(offsets.from) / 1_000,
                    end: Double(offsets.to) / 1_000,
                    probabilityTotal: token.p ?? 0,
                    probabilityCount: token.p == nil ? 0 : 1
                )
            } else if pending != nil {
                pending?.text += trimmed
                pending?.end = Double(offsets.to) / 1_000
                if let probability = token.p {
                    pending?.probabilityTotal += probability
                    pending?.probabilityCount += 1
                }
            } else {
                pending = .init(
                    text: trimmed,
                    start: Double(offsets.from) / 1_000,
                    end: Double(offsets.to) / 1_000,
                    probabilityTotal: token.p ?? 0,
                    probabilityCount: token.p == nil ? 0 : 1
                )
            }
        }
        try append(pending)
        return .init(text: transcript, language: payload.result.language, words: words)
    }
}

/// Conversion boundary for integer transcript timestamp columns.
/// Persistence requires an explicit unit scale instead of guessing one.
public struct LegacyTranscriptClock: Equatable, Sendable {
    public let unitsPerSecond: Int

    /// The v41 transcript schema stores start and duration as whole seconds,
    /// truncated toward zero from the transcriber's floating-point values.
    public static let rewind15607 = LegacyTranscriptClock(uncheckedUnitsPerSecond: 1)

    public init(unitsPerSecond: Int) throws {
        guard unitsPerSecond > 0 else {
            throw MeetingTranscriptionError.invalidLegacyClock(unitsPerSecond)
        }
        self.unitsPerSecond = unitsPerSecond
    }

    private init(uncheckedUnitsPerSecond: Int) {
        self.unitsPerSecond = uncheckedUnitsPerSecond
    }

    public func persistenceWords(
        from result: MeetingTranscriptionResult,
        speechSource: String,
        absoluteOffsetSeconds: TimeInterval = 0
    ) -> [LibreReverseTranscriptWordInput] {
        result.words.map { word in
            let start = max(0, absoluteOffsetSeconds + word.startSeconds)
            let duration = max(0, word.endSeconds - word.startSeconds)
            return .init(
                speechSource: speechSource,
                word: word.text,
                timeOffset: Int(start * Double(unitsPerSecond)),
                fullTextOffset: word.fullTextUTF16Offset,
                duration: Int(duration * Double(unitsPerSecond))
            )
        }
    }
}

/// Deterministic overlap reducer for streaming windows. Words at or beyond the
/// replacement boundary are replaced as a unit; words before the finalized
/// boundary can never be revised by a later retry.
public struct MeetingTranscriptAccumulator: Equatable, Sendable {
    public private(set) var words: [MeetingTranscriptionWord] = []
    public private(set) var finalizedThroughSeconds: TimeInterval = 0
    private var prefixMaximumEndSeconds: [TimeInterval] = []
    internal private(set) var lastReplacementBoundaryComparisonCount = 0

    public init() {}

    internal init(
        checkpointWords: [MeetingTranscriptionWord],
        finalizedThroughSeconds: TimeInterval
    ) throws {
        guard finalizedThroughSeconds.isFinite, finalizedThroughSeconds >= 0 else {
            throw MeetingTranscriptionError.invalidCheckpoint("invalid finalized boundary")
        }
        var previous: MeetingTranscriptionWord?
        var maxima: [TimeInterval] = []
        maxima.reserveCapacity(checkpointWords.count)
        var maximumEnd = -TimeInterval.infinity
        for word in checkpointWords {
            guard word.startSeconds.isFinite,
                word.endSeconds.isFinite,
                word.startSeconds >= 0,
                word.endSeconds >= word.startSeconds
            else {
                throw MeetingTranscriptionError.invalidCheckpoint("invalid word timing")
            }
            if let previous {
                guard
                    previous.startSeconds < word.startSeconds
                        || (previous.startSeconds == word.startSeconds
                            && previous.endSeconds <= word.endSeconds)
                else {
                    throw MeetingTranscriptionError.invalidCheckpoint("words are not sorted")
                }
            }
            maximumEnd = max(maximumEnd, word.endSeconds)
            maxima.append(maximumEnd)
            previous = word
        }
        words = checkpointWords
        self.finalizedThroughSeconds = finalizedThroughSeconds
        prefixMaximumEndSeconds = maxima
    }

    public mutating func apply(
        _ result: MeetingTranscriptionResult,
        windowStartSeconds: TimeInterval,
        replaceFromSeconds requestedReplacement: TimeInterval,
        finalizeThroughSeconds: TimeInterval? = nil
    ) {
        let replacement = max(finalizedThroughSeconds, requestedReplacement)
        let retainedCount = replacementBoundaryIndex(for: replacement)
        words.removeSubrange(retainedCount...)
        prefixMaximumEndSeconds.removeSubrange(retainedCount...)
        var incoming = result.words.compactMap { word -> MeetingTranscriptionWord? in
            let absoluteStart = windowStartSeconds + word.startSeconds
            let absoluteEnd = windowStartSeconds + word.endSeconds
            guard absoluteStart >= replacement else { return nil }
            return .init(
                text: word.text,
                startSeconds: absoluteStart,
                endSeconds: absoluteEnd,
                probability: word.probability,
                fullTextUTF16Offset: word.fullTextUTF16Offset
            )
        }
        incoming.sort {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.endSeconds < $1.endSeconds
        }
        words.append(contentsOf: incoming)
        var maximumEnd = prefixMaximumEndSeconds.last ?? -.infinity
        prefixMaximumEndSeconds.reserveCapacity(words.count)
        for word in incoming {
            maximumEnd = max(maximumEnd, word.endSeconds)
            prefixMaximumEndSeconds.append(maximumEnd)
        }
        if let finalizeThroughSeconds {
            self.finalizedThroughSeconds = max(
                self.finalizedThroughSeconds,
                finalizeThroughSeconds
            )
        }
    }

    /// Finds the first word whose end crosses the replacement boundary. The
    /// prefix maxima keep this logarithmic even when recognizer words overlap.
    private mutating func replacementBoundaryIndex(for boundary: TimeInterval) -> Int {
        var lowerBound = 0
        var upperBound = prefixMaximumEndSeconds.count
        var comparisons = 0
        while lowerBound < upperBound {
            comparisons += 1
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if prefixMaximumEndSeconds[midpoint] > boundary {
                upperBound = midpoint
            } else {
                lowerBound = midpoint + 1
            }
        }
        lastReplacementBoundaryComparisonCount = comparisons
        return lowerBound
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.words == rhs.words
            && lhs.finalizedThroughSeconds == rhs.finalizedThroughSeconds
    }

    public func result(language: String? = nil) -> MeetingTranscriptionResult {
        var text = ""
        var normalized: [MeetingTranscriptionWord] = []
        var utf16Offset = 0
        for word in words {
            if !text.isEmpty {
                text.append(" ")
                utf16Offset += 1
            }
            text.append(word.text)
            normalized.append(
                .init(
                    text: word.text,
                    startSeconds: word.startSeconds,
                    endSeconds: word.endSeconds,
                    probability: word.probability,
                    fullTextUTF16Offset: utf16Offset
                ))
            utf16Offset += word.text.utf16.count
        }
        return .init(text: text, language: language, words: normalized)
    }
}

public struct WhisperCPPCLIConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let modelURL: URL
    public let vadModelURL: URL?
    public let language: String?
    public let useGPU: Bool

    public init(
        executableURL: URL,
        modelURL: URL,
        language: String? = nil,
        useGPU: Bool = true,
        vadModelURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL
        self.language = language
        self.useGPU = useGPU
    }

    public func arguments(inputURL: URL, outputBaseURL: URL) -> [String] {
        var arguments = [
            "-m", modelURL.path,
            "-f", inputURL.path,
            "-ojf",
            "-of", outputBaseURL.path,
            "-np",
        ]
        arguments += ["-l", language ?? "auto"]
        if !useGPU { arguments.append("-ng") }
        if let vadModelURL { arguments += ["--vad", "--vad-model", vadModelURL.path] }
        return arguments
    }
}

public struct MeetingTranscriptCaptureOutcome: Equatable, Sendable {
    public let transcription: MeetingTranscriptionResult
    public let documentID: Int64?
}

internal struct MeetingTranscriptionCheckpointBinding: Codable, Equatable, Sendable {
    struct FileIdentity: Codable, Equatable, Sendable {
        let path: String
        let size: Int64?
        let modificationTime: TimeInterval?
    }

    let identifier: String
    let media: FileIdentity
    let executable: FileIdentity
    let model: FileIdentity
    let vadModel: FileIdentity?
    let language: String?
    let useGPU: Bool
    let windowSeconds: TimeInterval
    let overlapSeconds: TimeInterval
}

internal struct MeetingTranscriptionCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let binding: MeetingTranscriptionCheckpointBinding
    let nextWindowIndex: Int
    let finalizedThroughSeconds: TimeInterval
    let language: String?
    let words: [MeetingTranscriptionWord]

    init(
        binding: MeetingTranscriptionCheckpointBinding,
        nextWindowIndex: Int,
        finalizedThroughSeconds: TimeInterval,
        language: String?,
        words: [MeetingTranscriptionWord]
    ) {
        schemaVersion = 1
        self.binding = binding
        self.nextWindowIndex = nextWindowIndex
        self.finalizedThroughSeconds = finalizedThroughSeconds
        self.language = language
        self.words = words
    }
}

internal enum MeetingTranscriptionCheckpointStore {
    static func binding(
        context: MeetingTranscriptionCheckpointContext,
        mediaURL: URL,
        configuration: WhisperCPPCLIConfiguration,
        windowing: MeetingTranscriptionWindowingConfiguration
    ) throws -> MeetingTranscriptionCheckpointBinding {
        guard let media = fileIdentity(mediaURL, required: true) else {
            throw MeetingTranscriptionError.invalidCheckpoint(
                "published media could not be fingerprinted"
            )
        }
        return .init(
            identifier: context.identifier,
            media: media,
            executable: fileIdentity(configuration.executableURL, required: false)!,
            model: fileIdentity(configuration.modelURL, required: false)!,
            vadModel: configuration.vadModelURL.flatMap { fileIdentity($0, required: false) },
            language: configuration.language,
            useGPU: configuration.useGPU,
            windowSeconds: windowing.windowSeconds,
            overlapSeconds: windowing.overlapSeconds
        )
    }

    static func load(
        context: MeetingTranscriptionCheckpointContext,
        binding: MeetingTranscriptionCheckpointBinding,
        windows: [MeetingTranscriptionWindow]
    ) throws -> MeetingTranscriptionCheckpoint? {
        guard FileManager.default.fileExists(atPath: context.url.path) else { return nil }
        do {
            let key = try encryptionKey(context)
            let sealed = try AES.GCM.SealedBox(
                combined: Data(contentsOf: context.url)
            )
            let plaintext = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: Data(context.identifier.utf8)
            )
            let checkpoint = try JSONDecoder().decode(
                MeetingTranscriptionCheckpoint.self,
                from: plaintext
            )
            guard checkpoint.schemaVersion == 1,
                checkpoint.binding == binding,
                checkpoint.nextWindowIndex >= 0,
                checkpoint.nextWindowIndex <= windows.count
            else {
                throw MeetingTranscriptionError.invalidCheckpoint("binding or index mismatch")
            }
            let expectedFinalized =
                checkpoint.nextWindowIndex == 0
                ? 0
                : windows[checkpoint.nextWindowIndex - 1].finalizeThroughSeconds
            guard abs(checkpoint.finalizedThroughSeconds - expectedFinalized) < 0.000_001,
                checkpoint.nextWindowIndex > 0 || checkpoint.words.isEmpty
            else {
                throw MeetingTranscriptionError.invalidCheckpoint("boundary mismatch")
            }
            _ = try MeetingTranscriptAccumulator(
                checkpointWords: checkpoint.words,
                finalizedThroughSeconds: checkpoint.finalizedThroughSeconds
            )
            return checkpoint
        } catch {
            // A stale, partial, or corrupt sidecar can never be allowed to
            // poison the durable job. Discard it and recompute from window 0.
            try? FileManager.default.removeItem(at: context.url)
            return nil
        }
    }

    static func save(
        _ checkpoint: MeetingTranscriptionCheckpoint,
        context: MeetingTranscriptionCheckpointContext
    ) throws {
        try FileManager.default.createDirectory(
            at: context.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(checkpoint)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: try encryptionKey(context),
            authenticating: Data(context.identifier.utf8)
        )
        guard let combined = sealed.combined else {
            throw MeetingTranscriptionError.invalidCheckpoint("encryption produced no payload")
        }
        try combined.write(to: context.url, options: .atomic)
    }

    private static func encryptionKey(
        _ context: MeetingTranscriptionCheckpointContext
    ) throws -> SymmetricKey {
        let data = try Data(contentsOf: context.encryptionKeyURL)
        guard data.count >= 16 else {
            throw MeetingTranscriptionError.invalidCheckpoint("library key is unavailable")
        }
        // Existing checkpoints made with raw AES-sized test/import keys stay
        // readable. Product library keys are base64 passphrase bytes (44 bytes),
        // which AES rejects; derive a domain-separated 256-bit key for them.
        if [16, 24, 32].contains(data.count) { return SymmetricKey(data: data) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: data),
            salt: Data("LibreReverse".utf8),
            info: Data("meeting-transcription-checkpoint-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func fileIdentity(_ url: URL, required: Bool)
        -> MeetingTranscriptionCheckpointBinding.FileIdentity?
    {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if required, attributes == nil { return nil }
        return .init(
            path: url.standardizedFileURL.path,
            size: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationTime: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        )
    }
}

/// Bridges a local transcription backend to the canonical replacement
/// transaction. Capture and decoding remain independently testable;
/// persistence updates words and search documents together.
public actor MeetingTranscriptCaptureService {
    private let transcriber: any MeetingTranscriber
    private let clock: LegacyTranscriptClock
    private let speechSource: String

    public init(
        transcriber: any MeetingTranscriber,
        clock: LegacyTranscriptClock,
        speechSource: String
    ) {
        self.transcriber = transcriber
        self.clock = clock
        self.speechSource = speechSource
    }

    public func transcribeAndPersist(
        mediaURL: URL,
        segmentID: Int64,
        title: String,
        configuration: LibreReverseLibraryConfiguration,
        checkpoint: MeetingTranscriptionCheckpointContext? = nil
    ) async throws -> MeetingTranscriptCaptureOutcome {
        let result: MeetingTranscriptionResult
        if let checkpoint,
            let checkpointing = transcriber as? any CheckpointingMeetingTranscriber
        {
            result = try await checkpointing.transcribe(
                mediaURL: mediaURL,
                checkpoint: checkpoint
            )
        } else {
            result = try await transcriber.transcribe(mediaURL: mediaURL)
        }
        // A backend is allowed to use an API that does not itself cooperate
        // with Swift task cancellation. Never cross the durable commit boundary
        // after the owning queue task has been cancelled.
        try Task.checkCancellation()
        let documentID = try LibreReverseLibraryStore.replaceMeetingTranscript(
            segmentID: segmentID,
            title: title,
            transcriptText: result.text,
            words: clock.persistenceWords(from: result, speechSource: speechSource),
            configuration: configuration
        )
        return .init(transcription: result, documentID: documentID)
    }
}

/// Self-contained app backend. Captured movie audio is converted with
/// AVFoundation, so the bundled native CLI never depends on ffmpeg or Python.
public actor WhisperCPPCLITranscriber: CheckpointingMeetingTranscriber {
    internal typealias WAVInference =
        @Sendable (URL, URL) async throws
        -> MeetingTranscriptionResult

    private let configuration: WhisperCPPCLIConfiguration
    private let windowing: MeetingTranscriptionWindowingConfiguration
    private let inferenceOverride: WAVInference?

    public init(
        configuration: WhisperCPPCLIConfiguration,
        windowing: MeetingTranscriptionWindowingConfiguration = .production
    ) {
        self.configuration = configuration
        self.windowing = windowing
        inferenceOverride = nil
    }

    internal init(
        configuration: WhisperCPPCLIConfiguration,
        windowing: MeetingTranscriptionWindowingConfiguration,
        inference: @escaping WAVInference
    ) {
        self.configuration = configuration
        self.windowing = windowing
        inferenceOverride = inference
    }

    public func transcribe(mediaURL: URL) async throws -> MeetingTranscriptionResult {
        try await transcribeWindowed(mediaURL: mediaURL, checkpoint: nil)
    }

    public func transcribe(
        mediaURL: URL,
        checkpoint: MeetingTranscriptionCheckpointContext
    ) async throws -> MeetingTranscriptionResult {
        try await transcribeWindowed(mediaURL: mediaURL, checkpoint: checkpoint)
    }

    private func transcribeWindowed(
        mediaURL: URL,
        checkpoint: MeetingTranscriptionCheckpointContext?
    ) async throws -> MeetingTranscriptionResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-whisper-cpp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("meeting.wav")
        try await MeetingAudioPCMExporter.export16kMonoWAV(from: mediaURL, to: wavURL)
        let audioFile: AVAudioFile
        do { audioFile = try AVAudioFile(forReading: wavURL) } catch {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "open normalized meeting audio: \(String(describing: error))"
            )
        }
        let duration = TimeInterval(audioFile.length) / audioFile.processingFormat.sampleRate
        let windows = try MeetingTranscriptionWindowPlan.make(
            mediaDurationSeconds: duration,
            configuration: windowing
        )
        let binding = try checkpoint.map {
            try MeetingTranscriptionCheckpointStore.binding(
                context: $0,
                mediaURL: mediaURL,
                configuration: configuration,
                windowing: windowing
            )
        }
        let restored = try binding.flatMap {
            try MeetingTranscriptionCheckpointStore.load(
                context: checkpoint!,
                binding: $0,
                windows: windows
            )
        }
        var accumulator =
            try restored.map {
                try MeetingTranscriptAccumulator(
                    checkpointWords: $0.words,
                    finalizedThroughSeconds: $0.finalizedThroughSeconds
                )
            } ?? MeetingTranscriptAccumulator()
        var language = restored?.language
        let nextWindowIndex = restored?.nextWindowIndex ?? 0
        for window in windows.dropFirst(nextWindowIndex) {
            try Task.checkCancellation()
            let stem = String(format: "window-%05d", window.index)
            let windowURL = directory.appendingPathComponent(stem).appendingPathExtension("wav")
            try MeetingAudioPCMExporter.copyWindow(
                from: wavURL,
                to: windowURL,
                startSeconds: window.startSeconds,
                durationSeconds: window.durationSeconds
            )
            let result = try await transcribeWAV(
                windowURL,
                outputBase: directory.appendingPathComponent(stem)
            )
            if language == nil, let detected = result.language, !detected.isEmpty {
                language = detected
            }
            accumulator.apply(
                result,
                windowStartSeconds: window.startSeconds,
                replaceFromSeconds: window.replaceFromSeconds,
                finalizeThroughSeconds: window.finalizeThroughSeconds
            )
            if let checkpoint, let binding {
                try MeetingTranscriptionCheckpointStore.save(
                    .init(
                        binding: binding,
                        nextWindowIndex: window.index + 1,
                        finalizedThroughSeconds: accumulator.finalizedThroughSeconds,
                        language: language,
                        words: accumulator.words
                    ),
                    context: checkpoint
                )
            }
            try? FileManager.default.removeItem(at: windowURL)
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(stem).appendingPathExtension("json")
            )
        }
        return accumulator.result(language: language)
    }

    private func transcribeWAV(
        _ wavURL: URL,
        outputBase: URL
    ) async throws -> MeetingTranscriptionResult {
        if let inferenceOverride {
            return try await inferenceOverride(wavURL, outputBase)
        }
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments(inputURL: wavURL, outputBaseURL: outputBase)
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        let errorText =
            String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        guard process.terminationStatus == 0 else {
            throw MeetingTranscriptionError.processFailed(
                status: process.terminationStatus,
                message: errorText
            )
        }
        let outputURL = outputBase.appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw MeetingTranscriptionError.outputMissing(outputURL)
        }
        return try WhisperCPPJSONTranscriptDecoder.decode(Data(contentsOf: outputURL))
    }
}

/// Drains a started native export before acknowledging caller cancellation.
/// AVFoundation cancellation callbacks can precede output-path teardown, so an
/// admitted extraction finishes normally; subsequent PCM work stays cancellable.
internal final class MeetingAudioExportLifetime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LibreReverse.meeting-audio-export")
    private var cancelled = false
    private var finished = false
    private let start: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void
    init(start: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void) {
        self.start = start
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !cancelled else {
                        finished = true
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    start { error in
                        self.queue.async {
                            guard !self.finished else { return }
                            self.finished = true
                            if self.cancelled {
                                continuation.resume(throwing: CancellationError())
                            } else if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
            }
        }
        try Task.checkCancellation()
    }
}

internal enum MeetingAudioPCMExporter {
    static func export16kMonoWAV(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        // Canonical recordings deliberately have no extension. Match the
        // ordinary playback loader's container hint so AVFoundation can open
        // their audio tracks after publication or archive restoration.
        let options: [String: Any] = source.pathExtension.isEmpty
            ? ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"] : [:]
        let asset = AVURLAsset(url: source, options: options)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MeetingTranscriptionError.missingAudioTrack(source)
        }
        // AVFoundation can retain asynchronous output-path activity beyond its
        // completion callback. Never recycle an intermediate URL for another
        // export. Removing the owning directory also prevents a late create at
        // the old path from recreating a file after cleanup.
        let workspace = destination.deletingLastPathComponent()
            .appendingPathComponent(".meeting-pcm-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let intermediate = workspace.appendingPathComponent("audio.m4a")
        guard
            let export = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            )
        else {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "AVFoundation could not create an audio-only export session"
            )
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        export.audioMix = audioMix
        // Finish admitted extraction normally before honoring cancellation.
        // Both the async overlay and cancelExport's callback can finish before
        // native cancellation has stopped modifying the output path.
        export.outputURL = intermediate
        export.outputFileType = .m4a
        let session = MeetingUnsafeSendableBox(export)
        let lifetime = MeetingAudioExportLifetime(start: { completed in
            session.value.exportAsynchronously {
                if session.value.status == .completed {
                    completed(nil)
                } else {
                    completed(session.value.error ?? MeetingTranscriptionError.audioExtractionFailed(
                        "audio-only export did not complete"))
                }
            }
        })
        do {
            try Task.checkCancellation()
            try await lifetime.run()
        } catch {
            try Task.checkCancellation()
            throw MeetingTranscriptionError.audioExtractionFailed(
                "audio-only export: \(String(describing: error))")
        }
        try Task.checkCancellation()
        let inputFile: AVAudioFile
        do { inputFile = try AVAudioFile(forReading: intermediate) } catch {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "open audio-only export: \(String(describing: error))"
            )
        }
        let sourceFormat = inputFile.processingFormat
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "AVAudioConverter rejected \(sourceFormat) to 16 kHz mono PCM"
            )
        }
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destination,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "create WAV output: \(String(describing: error))"
            )
        }
        let inputCapacity: AVAudioFrameCount = 32_768
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: inputCapacity
            )
        else {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "could not allocate input PCM buffer")
        }
        while inputFile.framePosition < inputFile.length {
            try Task.checkCancellation()
            let remaining = inputFile.length - inputFile.framePosition
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(inputCapacity), remaining))
            do { try inputFile.read(into: inputBuffer, frameCount: requested) } catch {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "read audio-only export at \(inputFile.framePosition)/\(inputFile.length): "
                        + String(describing: error)
                )
            }
            guard inputBuffer.frameLength > 0 else {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "audio-only export returned zero frames before EOF"
                )
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputCapacity =
                AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                )
            else {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "could not allocate output PCM buffer"
                )
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    conversionError.map(String.init(describing:)) ?? "PCM conversion failed"
                )
            }
            if outputBuffer.frameLength > 0 {
                do { try outputFile.write(from: outputBuffer) } catch {
                    throw MeetingTranscriptionError.audioExtractionFailed(
                        "write WAV output: \(String(describing: error))"
                    )
                }
            }
        }
    }

    static func copyWindow(
        from source: URL,
        to destination: URL,
        startSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "open normalized audio window source: \(String(describing: error))"
            )
        }
        let format = input.processingFormat
        let startFrame = AVAudioFramePosition(floor(startSeconds * format.sampleRate))
        let requestedFrames = AVAudioFramePosition(ceil(durationSeconds * format.sampleRate))
        guard startFrame >= 0, startFrame < input.length, requestedFrames > 0 else {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "invalid normalized audio window \(startSeconds)+\(durationSeconds)"
            )
        }
        input.framePosition = startFrame
        let frameLimit = min(input.length, startFrame + requestedFrames)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "create normalized audio window: \(String(describing: error))"
            )
        }
        let capacity: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw MeetingTranscriptionError.audioExtractionFailed(
                "allocate normalized audio window buffer"
            )
        }
        while input.framePosition < frameLimit {
            let remaining = frameLimit - input.framePosition
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
            do { try input.read(into: buffer, frameCount: requested) } catch {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "read normalized audio window: \(String(describing: error))"
                )
            }
            guard buffer.frameLength > 0 else {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "normalized audio window returned zero frames before EOF"
                )
            }
            do { try output.write(from: buffer) } catch {
                throw MeetingTranscriptionError.audioExtractionFailed(
                    "write normalized audio window: \(String(describing: error))"
                )
            }
        }
    }
}

/// AVFoundation predates Swift concurrency. Access stays serialized inside the
/// transcriber actor; this wrapper exists only so cancellation can signal the
/// same export session from Swift's `@Sendable` cancellation closure.
private final class MeetingUnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

#endif
