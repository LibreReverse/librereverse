#if canImport(AVFoundation) && canImport(CoreGraphics)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

public enum FrameVideoWriterError: Error {
    case unsupportedFrameRate(Int32)
    case noOutputSettings
    case cannotAddInput
    case startWriting(Error?)
    case pixelBuffer(OSStatus)
    case appendFailed(Error?)
    case invalidDimensions
    case invalidLifecycle
    case backpressureTimedOut
}

@MainActor
public final class FrameVideoWriter {
    private struct PendingFrame {
        let number: Int64
        let buffer: CVPixelBuffer
    }

    public let outputURL: URL
    public let videoWidth: Int
    public let videoHeight: Int
    public let frameRate: Int32

    private let assetWriter: AVAssetWriter
    private let assetWriterInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private var pendingFrames: [PendingFrame] = []
    private enum Lifecycle {
        case writing, finishing, completed
        case failed(Error)
    }
    private var lifecycle: Lifecycle = .writing
    private let drainTimeout: Duration
    private let readinessOverride: (() -> Bool)?
    var pendingFrameCount: Int { pendingFrames.count }

    public convenience init(outputURL: URL, width: Int, height: Int, frameRate: Int32 = 30) throws {
        try self.init(outputURL: outputURL, width: width, height: height,
            frameRate: frameRate, drainTimeout: .seconds(30), readiness: nil)
    }

    init(outputURL: URL, width: Int, height: Int, frameRate: Int32 = 30,
         drainTimeout: Duration, readiness: (() -> Bool)?) throws {
        self.drainTimeout = drainTimeout
        self.readinessOverride = readiness
        guard frameRate == 30 else { throw FrameVideoWriterError.unsupportedFrameRate(frameRate) }
        self.outputURL = outputURL
        videoWidth = width
        videoHeight = height
        self.frameRate = frameRate

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings = try Self.outputSettings(width: width, height: height, frameRate: frameRate)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw FrameVideoWriterError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw FrameVideoWriterError.startWriting(writer.error) }
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        assetWriterInput = input
        pixelBufferAdaptor = adaptor
    }

    public static func outputSettings(width: Int, height: Int, frameRate: Int32) throws -> [String: Any] {
        guard let bitrate = WriterContract.averageBitRate(width: width, height: height, frameRate: frameRate) else {
            throw FrameVideoWriterError.unsupportedFrameRate(frameRate)
        }
        let presets: [AVOutputSettingsPreset] = [
            .hevc1920x1080,
            .hevc3840x2160,
            .hevc7680x4320,
        ]
        let candidates = presets.compactMap { AVOutputSettingsAssistant(preset: $0)?.videoSettings }
        guard var settings = candidates.first(where: {
            ($0[AVVideoHeightKey] as? NSNumber)?.intValue ?? 0 >= height
                && ($0[AVVideoWidthKey] as? NSNumber)?.intValue ?? 0 >= width
        }) ?? candidates.last else {
            throw FrameVideoWriterError.noOutputSettings
        }
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoAverageBitRateKey] = bitrate
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    @discardableResult
    public func write(frameNumber: Int64, image: CGImage) throws -> Bool {
        try checkCanWrite()
        guard image.width == videoWidth, image.height == videoHeight else {
            throw FrameVideoWriterError.invalidDimensions
        }
        let buffer = try pixelBuffer(from: image)
        return try append(frameNumber: frameNumber, buffer: buffer)
    }

    @discardableResult
    func write(frameNumber: Int64, frame: CapturedScreenFrame) throws -> Bool {
        try checkCanWrite()
        guard frame.image.width == videoWidth, frame.image.height == videoHeight else {
            throw FrameVideoWriterError.invalidDimensions
        }
        if let buffer = frame.pixelBuffer,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            CaptureDiffInstrumentation.signposter.emitEvent("NativeVideoBuffer")
            return try append(frameNumber: frameNumber, buffer: buffer)
        }
        return try write(frameNumber: frameNumber, image: frame.image)
    }

    private func append(frameNumber: Int64, buffer: CVPixelBuffer) throws -> Bool {
        pendingFrames.append(PendingFrame(number: frameNumber, buffer: buffer))
        do { try drainPendingFrames() }
        catch {
            abort(with: error)
            throw error
        }
        return true
    }

    func checkCanWrite() throws {
        switch lifecycle {
        case .writing: return
        case .failed(let error): throw error
        default: throw FrameVideoWriterError.invalidLifecycle
        }
    }

    func abort(with error: Error) {
        if case .completed = lifecycle { return }
        lifecycle = .failed(error)
        if assetWriter.status == .writing { assetWriter.cancelWriting() }
        pendingFrames.removeAll()
    }

    public func drainPendingFrames() throws {
        while !pendingFrames.isEmpty,
              readinessOverride?() ?? true,
              assetWriterInput.isReadyForMoreMediaData {
            let pending = pendingFrames[0]
            let time = CMTimeMake(value: pending.number, timescale: 30)
            guard pixelBufferAdaptor.append(pending.buffer, withPresentationTime: time) else {
                throw FrameVideoWriterError.appendFailed(assetWriter.error)
            }
            pendingFrames.removeFirst()
        }
    }

    public func finish() async throws {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("VideoEncoderFinish", id: signposter.makeSignpostID())
        defer { signposter.endInterval("VideoEncoderFinish", interval) }
        switch lifecycle {
        case .completed: return
        case .failed(let error): throw error
        case .finishing: throw FrameVideoWriterError.invalidLifecycle
        case .writing: lifecycle = .finishing
        }
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: drainTimeout)
            while !pendingFrames.isEmpty {
                try Task.checkCancellation()
                guard assetWriter.status == .writing else {
                    throw FrameVideoWriterError.appendFailed(assetWriter.error)
                }
                try drainPendingFrames()
                guard !pendingFrames.isEmpty else { break }
                guard clock.now < deadline else {
                    throw FrameVideoWriterError.backpressureTimedOut
                }
                // Yield the main actor so AVFoundation can make progress and
                // UI/termination work remains responsive during encoder pressure.
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            assetWriterInput.markAsFinished()
            await withTaskCancellationHandler {
                await assetWriter.finishWriting()
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.assetWriter.status == .writing { self?.assetWriter.cancelWriting() }
                }
            }
            try Task.checkCancellation()
            guard assetWriter.status == .completed else {
                throw FrameVideoWriterError.appendFailed(assetWriter.error)
            }
            lifecycle = .completed
        } catch {
            // The recorder must observe failure on every later finish attempt,
            // so it never commits this incomplete file or deletes source PNGs.
            abort(with: error)
            throw error
        }
    }

    private func pixelBuffer(from source: CGImage) throws -> CVPixelBuffer {
        let signposter = CaptureDiffInstrumentation.signposter
        let interval = signposter.beginInterval("VideoPrepare", id: signposter.makeSignpostID())
        defer { signposter.endInterval("VideoPrepare", interval) }
        let image = try Self.convertedToBGRA(source)
        guard let pool = pixelBufferAdaptor.pixelBufferPool else {
            throw FrameVideoWriterError.pixelBuffer(kCVReturnInvalidArgument)
        }
        var candidate: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &candidate)
        guard status == kCVReturnSuccess, let buffer = candidate,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw FrameVideoWriterError.pixelBuffer(status)
        }
        if let space = image.colorSpace {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw FrameVideoWriterError.pixelBuffer(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else {
            throw FrameVideoWriterError.pixelBuffer(kCVReturnInvalidArgument)
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<image.height {
            memcpy(destination.advanced(by: row * stride),
                   bytes.advanced(by: row * image.bytesPerRow), image.width * 4)
        }
        return buffer
    }

    private static func convertedToBGRA(_ image: CGImage) throws -> CGImage {
        let alpha = image.alphaInfo
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        if byteOrder == .byteOrder32Little && (alpha == .premultipliedFirst || alpha == .first) {
            return image
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            throw FrameVideoWriterError.pixelBuffer(kCVReturnInvalidArgument)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else {
            throw FrameVideoWriterError.pixelBuffer(kCVReturnInvalidArgument)
        }
        return converted
    }
}
#endif
