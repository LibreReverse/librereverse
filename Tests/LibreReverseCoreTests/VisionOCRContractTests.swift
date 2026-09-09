#if os(macOS) && canImport(Vision)
import Vision
import ImageIO
import XCTest
@testable import LibreReverseCore

final class VisionOCRContractTests: XCTestCase {
    func testAdditionalLanguageRequestPreservesAccurateRecognition() throws {
        let request = try VisionOCRContract.makeRequest()
        XCTAssertEqual(request.revision, 3)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertEqual(request.minimumTextHeight, 0)
        XCTAssertFalse(request.usesLanguageCorrection)
        XCTAssertEqual(
            request.recognitionLanguages,
            try request.supportedRecognitionLanguages()
        )
        XCTAssertEqual(VisionOCRContract.processingTimeout, 10)
        XCTAssertEqual(VisionOCRContract.queueLabel, "frame-text-processing")
    }

    func testResourceSavingRequestRestrictsRecognitionToDocumentedStandardLanguages() throws {
        let request = try VisionOCRContract.makeRequest(
            additionalLanguageSupport: false
        )
        XCTAssertEqual(request.recognitionLevel, .fast)
        XCTAssertEqual(request.revision, 3)
        let primaryLanguages = Set(request.recognitionLanguages.compactMap {
            $0.split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first.map(String.init)?.lowercased()
        })
        XCTAssertFalse(primaryLanguages.isEmpty)
        XCTAssertTrue(primaryLanguages.isSubset(of: ["en", "fr", "it", "de", "es", "pt"]))
    }

    func testOCRTimeoutRaceAcceptsExactlyOneWinner() {
        for _ in 0..<2_000 {
            let state = VisionOCRRaceState()
            let group = DispatchGroup()
            let lock = NSLock()
            var recognitionWon = false
            var timeoutWon = false
            group.enter()
            DispatchQueue.global().async {
                let won = state.tryWinRecognition()
                lock.lock(); recognitionWon = won; lock.unlock()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                let won = state.tryWinTimeout()
                lock.lock(); timeoutWon = won; lock.unlock()
                group.leave()
            }
            group.wait()
            XCTAssertNotEqual(recognitionWon, timeoutWon)
            XCTAssertEqual(state.didTimeOut, timeoutWon)
        }
    }

    func testCoordinatorDeletesSourceOnlyAfterVideoAndOCRAreDurable() async throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try admitFrame(configuration: configuration, imageName: "race.png")
        let imageURL = sourceImageURL(configuration, "race.png")
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Self.writePNG(Self.onePixelImage(), to: imageURL)
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: frame.id, status: .success, configuration: configuration
        )

        let coordinator = LibreReverseOCRCoordinator(configuration: configuration) { _, _ in
            OCRDocument(text: "durable", otherText: "", nodes: [])
        }
        await withCheckedContinuation { continuation in
            coordinator.enqueue(
                frameID: frame.id,
                imageFileName: frame.imageFileName,
                displayBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                frontWindowBounds: nil
            ) { result in
                if case let .failure(error) = result {
                    XCTFail("unexpected OCR failure: \(error)")
                }
                continuation.resume()
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(try LibreReverseLibraryStore.pendingOCRFrameIDs(
            configuration: configuration
        ).isEmpty)
    }

    func testLaunchRecoveryProcessesOnlyDurableQueueAndRetainsFailures() async throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try admitFrame(configuration: configuration, imageName: "good.png")
        let bad = try admitFrame(configuration: configuration, imageName: "bad.png")
        let later = try admitFrame(configuration: configuration, imageName: "later.png")
        for frame in [good, bad, later] {
            let url = sourceImageURL(configuration, frame.imageFileName)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.writePNG(Self.onePixelImage(), to: url)
            try LibreReverseLibraryStore.updateFrameEncodingStatus(
                frameID: frame.id, status: .success, configuration: configuration
            )
        }
        let coordinator = LibreReverseOCRCoordinator(configuration: configuration) { image, _ in
            guard image.width == 1 else { throw RecoveryTestError.expectedFailure }
            return OCRDocument(text: "recovered", otherText: "", nodes: [])
        }
        // Replace the second valid PNG with bytes ImageIO cannot decode. It
        // must remain queued while the first item completes.
        try Data("not an image".utf8).write(
            to: sourceImageURL(configuration, bad.imageFileName), options: .atomic
        )

        let recovered = await coordinator.recoverPendingSourceImages()
        XCTAssertEqual(recovered, 2)
        XCTAssertEqual(
            try LibreReverseLibraryStore.pendingOCRFrameIDs(configuration: configuration),
            [bad.id]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, good.imageFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, bad.imageFileName).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, later.imageFileName).path
        ))
    }

    func testLaunchReconciliationDeletesOnlyProvenDurableSourceImages() async throws {
        let (root, configuration) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let removable = try admitFrame(configuration: configuration, imageName: "done.png")
        let pending = try admitFrame(configuration: configuration, imageName: "pending.png")
        let unencoded = try admitFrame(configuration: configuration, imageName: "raw.png")
        let escaping = try admitFrame(configuration: configuration, imageName: "../escape.png")
        let orphanURL = sourceImageURL(configuration, "orphan.png")
        let escapeURL = configuration.mediaRoot
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent("escape.png")
        for name in ["done.png", "pending.png", "raw.png", "orphan.png"] {
            let url = sourceImageURL(configuration, name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("source".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: escapeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("must remain".utf8).write(to: escapeURL)
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: removable.id, status: .success, configuration: configuration
        )
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: removable.id,
            document: OCRDocument(text: "done", otherText: "", nodes: []),
            configuration: configuration
        )
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: pending.id, status: .success, configuration: configuration
        )
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: unencoded.id,
            document: OCRDocument(text: "raw", otherText: "", nodes: []),
            configuration: configuration
        )
        try LibreReverseLibraryStore.updateFrameEncodingStatus(
            frameID: escaping.id, status: .success, configuration: configuration
        )
        try LibreReverseLibraryStore.commitOCRDocument(
            frameID: escaping.id,
            document: OCRDocument(text: "escape", otherText: "", nodes: []),
            configuration: configuration
        )

        let candidates = try LibreReverseLibraryStore.removableSourceImages(
            configuration: configuration
        )
        XCTAssertEqual(candidates, [
            LibreReverseRemovableSourceImage(
                frameID: removable.id, imageFileName: removable.imageFileName
            ),
            LibreReverseRemovableSourceImage(
                frameID: escaping.id, imageFileName: escaping.imageFileName
            ),
        ])
        let coordinator = LibreReverseOCRCoordinator(configuration: configuration) { _, _ in
            XCTFail("reconciliation must not invoke OCR")
            return OCRDocument(text: "", otherText: "", nodes: [])
        }
        let removed = await coordinator.reconcileDurableSourceImages()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, removable.imageFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, pending.imageFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sourceImageURL(configuration, unencoded.imageFileName).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: escapeURL.path))
    }

    private enum RecoveryTestError: Error { case expectedFailure }

    private func makeLibrary() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("librereverse-ocr-coordinator-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media", isDirectory: true)
        )
        try LibreReverseLibraryStore.initialize(configuration)
        return (root, configuration)
    }

    private func admitFrame(
        configuration: LibreReverseLibraryConfiguration,
        imageName: String
    ) throws -> LibreReverseAdmittedFrame {
        try LibreReverseLibraryStore.admitFrame(
            createdAt: Date(), imageFileName: imageName,
            context: .init(bundleID: "com.example.Test", windowName: "Test"),
            configuration: configuration
        )
    }

    private func sourceImageURL(
        _ configuration: LibreReverseLibraryConfiguration,
        _ name: String
    ) -> URL {
        configuration.mediaRoot
            .appendingPathComponent("temp/images", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func onePixelImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
