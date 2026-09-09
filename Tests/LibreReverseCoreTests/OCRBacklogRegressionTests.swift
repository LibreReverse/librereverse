#if os(macOS) && canImport(Vision)
import CSQLCipher
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LibreReverseCore

final class OCRBacklogRegressionTests: XCTestCase {
    func testBlockedRecognitionDecodesOnlyOneImageAndEventuallyCommitsEveryJob() async throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFrames(count: 64, configuration: configuration)
        let source = try Self.image()
        for id in 1...64 {
            try Self.writePNG(source, to: configuration.frameImagesRoot.appendingPathComponent("\(id).png"))
        }
        let began = expectation(description: "first recognition began")
        let completed = expectation(description: "every durable frame processed")
        completed.expectedFulfillmentCount = 64
        let blocker = DispatchSemaphore(value: 0)
        let probe = ImageLifetimeProbe()
        let coordinator = LibreReverseOCRCoordinator(configuration: configuration,
            recognition: { _, bounds in
                XCTAssertEqual(bounds, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
                if probe.recognitionStarted() == 1 {
                    began.fulfill()
                    XCTAssertEqual(blocker.wait(timeout: .now() + 10), .success)
                }
                return OCRDocument(text: "recognized", otherText: "", nodes: [])
            }, imageLoader: { url in
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                return try probe.makeImage()
            })
        func enqueue(_ id: Int64) {
            coordinator.enqueue(frameID: id, imageFileName: "\(id).png",
                displayBounds: CGRect(x: 0, y: 0, width: 4, height: 4),
                frontWindowBounds: CGRect(x: 1, y: 1, width: 2, height: 2)) { result in
                    if case .failure(let error) = result { XCTFail("OCR failed: \(error)") }
                    completed.fulfill()
                }
        }
        enqueue(1)
        await fulfillment(of: [began], timeout: 5)
        for id in 2...64 { enqueue(Int64(id)) }
        XCTAssertEqual(probe.snapshot.loaded, 1, "Queued jobs must not predecode or retain capture images")
        XCTAssertEqual(probe.snapshot.live, 1)
        blocker.signal()
        await fulfillment(of: [completed], timeout: 20)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(probe.snapshot.loaded, 64)
        XCTAssertEqual(probe.snapshot.maximumLive, 1)
        XCTAssertEqual(probe.snapshot.live, 0)
        XCTAssertTrue(try LibreReverseLibraryStore.pendingOCRFrameIDs(limit: 100,
            configuration: configuration).isEmpty)
        // Unencoded frames retain their sources even after successful OCR.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: configuration.frameImagesRoot.path).count, 64)
    }

    func testRecoveryPassesTenThousandMissingImagesAndProcessesLaterValidFrame() async throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFrames(count: 10_001, configuration: configuration)
        try Self.writePNG(Self.image(),
            to: configuration.frameImagesRoot.appendingPathComponent("10001.png"))
        let coordinator = LibreReverseOCRCoordinator(configuration: configuration) { _, _ in
            OCRDocument(text: "late valid frame", otherText: "", nodes: [])
        }
        let recovered = await coordinator.recoverPendingSourceImages()
        XCTAssertEqual(recovered, 1)
        let remaining = try LibreReverseLibraryStore.pendingOCRFrameIDs(limit: 10_002,
            configuration: configuration)
        XCTAssertEqual(remaining.count, 10_000)
        XCTAssertFalse(remaining.contains(10_001))
        await coordinator.waitUntilIdle()
    }

    func testRecoverySnapshotDoesNotConsumeNewLiveAdmissions() async throws {
        let (root, configuration) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedFrames(count: 1, configuration: configuration)
        try Self.writePNG(Self.image(), to: configuration.frameImagesRoot.appendingPathComponent("1.png"))
        let probe = ImageLifetimeProbe()
        let coordinator = LibreReverseOCRCoordinator(configuration: configuration) { _, _ in
            if probe.recognitionStarted() == 1 {
                let newFrame = try LibreReverseLibraryStore.admitFrame(
                    createdAt: Date(), imageFileName: "new-live.png",
                    context: .init(bundleID: "com.example.Audit", windowName: "New live frame"),
                    configuration: configuration)
                XCTAssertGreaterThan(newFrame.id, 1)
                try Self.writePNG(Self.image(), to: configuration.frameImagesRoot.appendingPathComponent("new-live.png"))
            }
            return OCRDocument(text: "old backlog", otherText: "", nodes: [])
        }
        let recovered = await coordinator.recoverPendingSourceImages()
        XCTAssertEqual(recovered, 1)
        let pending = try LibreReverseLibraryStore.pendingOCRFrames(configuration: configuration)
        XCTAssertEqual(pending.map(\.imageFileName), ["new-live.png"])
        await coordinator.waitUntilIdle()
    }

    private func library() throws -> (URL, LibreReverseLibraryConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-backlog-\(UUID().uuidString)")
        let configuration = LibreReverseLibraryConfiguration(
            databaseURL: root.appendingPathComponent("Library/library.sqlite3"),
            keyFileURL: root.appendingPathComponent("Secrets/library-db-key"),
            mediaRoot: root.appendingPathComponent("Library/Media"))
        try LibreReverseLibraryStore.initialize(configuration)
        try FileManager.default.createDirectory(at: configuration.frameImagesRoot, withIntermediateDirectories: true)
        return (root, configuration)
    }

    private func seedFrames(count: Int, configuration: LibreReverseLibraryConfiguration) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(configuration.databaseURL.path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        defer { sqlite3_close(database) }
        let key = try Data(contentsOf: configuration.keyFileURL)
        XCTAssertEqual(key.withUnsafeBytes { sqlite3_key(database, $0.baseAddress, Int32($0.count)) }, SQLITE_OK)
        let sql = """
            BEGIN;
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(1,'com.example.Audit','2026-09-07T12:00:00.000','2026-09-07T12:00:01.000','Audit',0);
            WITH RECURSIVE numbers(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM numbers WHERE id<\(count))
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,encodingStatus)
            SELECT id,'2026-09-07T12:00:00.000',id||'.png',1,'deferred' FROM numbers;
            INSERT INTO frame_processing(id,processingType) SELECT id,'ocr' FROM frame;
            COMMIT;
            """
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? "SQLite status \(status)"
        sqlite3_free(error)
        XCTAssertEqual(status, SQLITE_OK, message)
    }

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class ImageLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = 0
    private var live = 0
    private var maximumLive = 0
    private var recognitionCalls = 0

    var snapshot: (loaded: Int, live: Int, maximumLive: Int) {
        lock.lock(); defer { lock.unlock() }
        return (loaded, live, maximumLive)
    }

    func recognitionStarted() -> Int {
        lock.lock(); defer { lock.unlock() }
        recognitionCalls += 1
        return recognitionCalls
    }

    func makeImage() throws -> CGImage {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        bytes.initializeMemory(as: UInt8.self, repeating: 255, count: 4)
        lock.lock()
        loaded += 1; live += 1; maximumLive = max(maximumLive, live)
        lock.unlock()
        let info = Unmanaged.passRetained(self).toOpaque()
        let provider = CGDataProvider(dataInfo: info, data: bytes, size: 4) { info, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
            let probe = Unmanaged<ImageLifetimeProbe>.fromOpaque(info!).takeRetainedValue()
            probe.lock.lock(); probe.live -= 1; probe.lock.unlock()
        }!
        return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
#endif
