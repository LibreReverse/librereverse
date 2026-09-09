#if os(macOS) && canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum VisionOCRError: Error, Equatable {
    case timedOut
    case sourceImageUnavailable
}

/// OCR request settings shared by foreground capture and background recovery.
public enum VisionOCRContract {
    public static let revision = 3
    public static let processingTimeout: TimeInterval = 10
    public static let queueLabel = "frame-text-processing"

    public static func makeRequest() throws -> VNRecognizeTextRequest {
        try makeRequest(additionalLanguageSupport: true)
    }

    public static func makeRequest(additionalLanguageSupport: Bool) throws
        -> VNRecognizeTextRequest
    {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        // Standard mode favors low background CPU; the opt-in expanded
        // language mode keeps the accurate model required for those scripts.
        request.recognitionLevel = additionalLanguageSupport ? .accurate : .fast
        request.minimumTextHeight = 0
        request.usesLanguageCorrection = false
        // Query languages for the chosen revision AND recognition level; fast
        // and accurate recognition do not support identical language sets.
        let supported = try request.supportedRecognitionLanguages()
        if additionalLanguageSupport {
            request.recognitionLanguages = supported
        } else {
            let standardLanguages: Set<String> = ["en", "fr", "it", "de", "es", "pt"]
            let standard = supported.filter { language in
                let primary = language
                    .split(whereSeparator: { $0 == "-" || $0 == "_" })
                    .first.map(String.init)?.lowercased()
                return primary.map(standardLanguages.contains) ?? false
            }
            // A future Vision revision may expose non-BCP-47 identifiers. In
            // that case preserve OCR rather than installing an empty list.
            request.recognitionLanguages = standard.isEmpty ? supported : standard
        }
        return request
    }
}

public final class VisionOCRRecognizer: @unchecked Sendable {
    private let languageModeLock = NSLock()
    private var additionalLanguageSupport: Bool

    public init(additionalLanguageSupport: Bool = true) {
        self.additionalLanguageSupport = additionalLanguageSupport
    }

    public func updateAdditionalLanguageSupport(_ enabled: Bool) {
        languageModeLock.lock()
        additionalLanguageSupport = enabled
        languageModeLock.unlock()
    }

    public func recognize(
        image: CGImage,
        normalizedFrontWindowBounds: CGRect?,
        timeout: TimeInterval = VisionOCRContract.processingTimeout
    ) throws -> OCRDocument {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("OCRRecognize", id: signposter.makeSignpostID())
        defer { signposter.endInterval("OCRRecognize", interval) }
        languageModeLock.lock()
        let additionalLanguageSupport = self.additionalLanguageSupport
        languageModeLock.unlock()
        let request = try VisionOCRContract.makeRequest(
            additionalLanguageSupport: additionalLanguageSupport
        )
        let timeoutState = VisionOCRRaceState()
        let timeoutWork = DispatchWorkItem { [weak request] in
            if timeoutState.tryWinTimeout() { request?.cancel() }
        }
        if timeout > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWork
            )
        }
        defer { timeoutWork.cancel() }

        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
        } catch {
            if timeoutState.didTimeOut { throw VisionOCRError.timedOut }
            _ = timeoutState.tryWinRecognition()
            throw error
        }
        guard timeoutState.tryWinRecognition() else {
            throw VisionOCRError.timedOut
        }

        let observations = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                OCRObservation(text: $0.string, boundingBox: observation.boundingBox)
            }
        }
        return OCRTextAssembly.assemble(
            observations: observations,
            normalizedFrontWindowBounds: normalizedFrontWindowBounds
        )
    }

}

/// Atomic winner gate for the app's OCR-vs-timeout race. Cancelling a
/// `DispatchWorkItem` does not stop a block that has already begun, so a plain
/// timeout boolean can falsely turn a completed OCR request into a timeout.
/// The gate accepts one completion and cancels the losing operation.
final class VisionOCRRaceState: @unchecked Sendable {
    private enum Winner { case pending, recognition, timeout }
    private let lock = NSLock()
    private var winner = Winner.pending

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return winner == .timeout
    }

    @discardableResult
    func tryWinTimeout() -> Bool { trySetWinner(.timeout) }

    @discardableResult
    func tryWinRecognition() -> Bool { trySetWinner(.recognition) }

    private func trySetWinner(_ candidate: Winner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard winner == .pending else { return winner == candidate }
        winner = candidate
        return true
    }
}

/// Serial bridge that keeps capture responsive using a dedicated
/// `frame-text-processing` dispatch queue. Failed work remains present in
/// `frame_processing` for launch recovery.
public final class LibreReverseOCRCoordinator: @unchecked Sendable {
    public typealias Recognition = @Sendable (CGImage, CGRect?) throws -> OCRDocument

    private let queue: DispatchQueue
    private let databaseSession: LibreReverseLibraryWriteSession
    private let configuration: LibreReverseLibraryConfiguration
    private let recognition: Recognition
    private let recognizer: VisionOCRRecognizer?
    typealias ImageLoading = @Sendable (URL) throws -> CGImage
    private let imageLoader: ImageLoading
    static let recoveryPageSize = 256

    public convenience init(
        configuration: LibreReverseLibraryConfiguration,
        recognition: Recognition? = nil
    ) {
        self.init(configuration: configuration, recognition: recognition,
                  imageLoader: Self.readSourceImage)
    }

    init(configuration: LibreReverseLibraryConfiguration,
         recognition: Recognition?, imageLoader: @escaping ImageLoading) {
        self.configuration = configuration
        self.imageLoader = imageLoader
        databaseSession = LibreReverseLibraryWriteSession(configuration: configuration)
        queue = DispatchQueue(label: VisionOCRContract.queueLabel, qos: .utility, autoreleaseFrequency: .workItem)
        if let recognition {
            self.recognition = recognition
            recognizer = nil
        } else {
            let recognizer = VisionOCRRecognizer()
            self.recognizer = recognizer
            self.recognition = { image, windowBounds in
                try recognizer.recognize(
                    image: image,
                    normalizedFrontWindowBounds: windowBounds
                )
            }
        }
    }

    public func updateAdditionalLanguageSupport(_ enabled: Bool) {
        recognizer?.updateAdditionalLanguageSupport(enabled)
    }

    /// Admission has already published the PNG. Queue only its durable identity
    /// and geometry; decode inside the serial worker so slow OCR cannot retain
    /// an unbounded backlog of full-resolution capture surfaces.
    public func enqueue(
        frameID: Int64,
        imageFileName: String,
        displayBounds: CGRect,
        frontWindowBounds: CGRect?,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        let normalizedWindow = OCRTextAssembly.normalizedWindowBounds(
            displayBounds: displayBounds,
            frontWindowBounds: frontWindowBounds
        )
        let configuration = configuration
        let databaseSession = databaseSession
        let recognition = recognition
        let imageLoader = imageLoader
        queue.async {
            let result = Result {
                try autoreleasepool {
                    try Self.processSourceImage(frameID: frameID,
                        imageFileName: imageFileName, normalizedWindow: normalizedWindow,
                        configuration: configuration, session: databaseSession,
                        recognition: recognition, imageLoader: imageLoader)
                }
            }
            completion?(result)
        }
    }

    /// Replay the durable OCR backlog present when recovery starts. Failed rows
    /// keep their PNG and queue entry but do not prevent later pages from running.
    /// Geometry is not persisted in frame_processing, so recovery uses front text.
    @discardableResult
    public func recoverPendingSourceImages() async -> Int {
        await withCheckedContinuation { continuation in
            let configuration = configuration
            let databaseSession = databaseSession
            let recognition = recognition
            let imageLoader = imageLoader
            queue.async {
                var completed = 0
                defer { continuation.resume(returning: completed) }
                do {
                    guard let highWatermark = try LibreReverseLibraryStore.pendingOCRFrameHighWatermark(
                        configuration: configuration, session: databaseSession) else { return }
                    var cursor: Int64?
                    while true {
                        let pending = try LibreReverseLibraryStore.pendingOCRFrames(
                            limit: Self.recoveryPageSize, afterFrameID: cursor,
                            configuration: configuration, session: databaseSession)
                        guard !pending.isEmpty else { return }
                        for frame in pending {
                            guard frame.id <= highWatermark else { return }
                            // Advance even when the file is absent or recognition fails.
                            cursor = frame.id
                            do {
                                try autoreleasepool {
                                    try Self.processSourceImage(frameID: frame.id,
                                        imageFileName: frame.imageFileName, normalizedWindow: nil,
                                        configuration: configuration, session: databaseSession,
                                        recognition: recognition, imageLoader: imageLoader)
                                }
                                completed += 1
                            } catch {
                                // Durable work survives for the next recovery attempt.
                            }
                        }
                        if cursor == highWatermark || pending.count < Self.recoveryPageSize { return }
                    }
                } catch {
                    // A failed page read preserves the remaining durable backlog.
                }
            }
        }
    }

    private static func processSourceImage(
        frameID: Int64, imageFileName: String, normalizedWindow: CGRect?,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession, recognition: Recognition,
        imageLoader: ImageLoading
    ) throws {
        guard let imageURL = directChildURL(named: imageFileName,
                                            under: configuration.frameImagesRoot) else {
            throw VisionOCRError.sourceImageUnavailable
        }
        let image = try imageLoader(imageURL)
        let document = try recognition(image, normalizedWindow)
        try LibreReverseLibraryStore.commitOCRDocument(frameID: frameID,
            document: document, configuration: configuration, session: session)
        try removeSourceImageIfFullyDurable(frameID: frameID,
            imageFileName: imageFileName, configuration: configuration, session: session)
    }

    private static func readSourceImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionOCRError.sourceImageUnavailable
        }
        return image
    }

    /// Closes the narrow crash window after both durable commits but before
    /// source-PNG deletion. Files without a proven primary Frame owner are
    /// deliberately untouched.
    @discardableResult
    public func reconcileDurableSourceImages() async -> Int {
        await withCheckedContinuation { continuation in
            let configuration = configuration
            let databaseSession = databaseSession
            queue.async {
                let imageRoot = configuration.mediaRoot
                    .appendingPathComponent("temp", isDirectory: true)
                    .appendingPathComponent("images", isDirectory: true)
                // Enumerate actual files once, instead of stat-ing every old
                // successful frame in the database on each launch.
                let existingNames = Set((try? FileManager.default.contentsOfDirectory(
                    atPath: imageRoot.path)) ?? [])
                guard !existingNames.isEmpty else {
                    continuation.resume(returning: 0)
                    return
                }
                let candidates = (try? LibreReverseLibraryStore.removableSourceImages(
                    configuration: configuration, session: databaseSession
                )) ?? []
                var removed = 0
                for candidate in candidates {
                    guard existingNames.contains(candidate.imageFileName) else { continue }
                    guard let url = Self.directChildURL(
                        named: candidate.imageFileName,
                        under: imageRoot
                    ) else { continue }
                    do {
                        try FileManager.default.removeItem(at: url)
                        removed += 1
                    } catch {
                        // A later launch retries only the same proven-safe file.
                    }
                }
                continuation.resume(returning: removed)
            }
        }
    }

    /// A shard rollover must not swap the primary database while queued OCR
    /// writes still target frame IDs in that primary.
    public func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                databaseSession.close()
                continuation.resume()
            }
        }
    }


    private static func removeSourceImageIfFullyDurable(
        frameID: Int64,
        imageFileName: String,
        configuration: LibreReverseLibraryConfiguration,
        session: LibreReverseLibraryWriteSession
    ) throws {
        guard try LibreReverseLibraryStore.canRemoveSourceImage(
            frameID: frameID,
            configuration: configuration, session: session
        ) else { return }
        let imageRoot = configuration.mediaRoot
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        guard let imageURL = directChildURL(named: imageFileName, under: imageRoot) else { return }
        try? FileManager.default.removeItem(at: imageURL)
    }

    private static func directChildURL(named fileName: String, under directory: URL) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              (fileName as NSString).lastPathComponent == fileName
        else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}
#endif
