#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import os

/// Serializes reference-frame ownership and keeps conversion and GPU waits off
/// the main actor. CPU mode also provides a deterministic benchmark/reference.
public actor ScreenDifferenceWorker {
    public enum Backend: Sendable { case automatic, cpu, metal }
    private let backend: Backend
    private var cpu = ScreenDiffer()
    private var gpu: MetalScreenDiffer?
    private var initialized = false

    public init(backend: Backend = .automatic) { self.backend = backend }

    public func process(_ frame: CapturedScreenFrame) throws -> ScreenDifferenceDecision {
        let interval = CaptureDiffInstrumentation.signposter.beginInterval("ScreenDifference", id: CaptureDiffInstrumentation.signposter.makeSignpostID())
        defer { CaptureDiffInstrumentation.signposter.endInterval("ScreenDifference", interval) }
        if !initialized {
            if backend != .cpu {
                if let device = MTLCreateSystemDefaultDevice() {
                    gpu = try MetalScreenDiffer(device: device)
                } else if backend == .metal {
                    throw MetalScreenDifferError.unavailable
                }
            }
            initialized = true
        }
        if let gpu { return try gpu.process(frame) }
        return try cpu.process(frame)
    }
}

enum CaptureDiffInstrumentation {
    static let signposter = OSSignposter(subsystem: "local.librereverse", category: .pointsOfInterest)
}

enum MetalScreenDifferError: Error {
    case unavailable, allocation, commandEncoding, execution(String)
}

/// Counts RGB changes against a separate reference for each display.
/// The result controls admission; the writer persists the unmodified screenshot.
private final class MetalScreenDiffer {
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void captureDiff(
        texture2d<float, access::read> previous [[texture(0)]],
        texture2d<float, access::read> current [[texture(1)]],
        device atomic_uint &count [[buffer(0)]],
        constant float &menuHeight [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]],
        uint lane [[thread_index_in_simdgroup]]) {
        uint changed = 0;
        if (gid.x < current.get_width() && gid.y < current.get_height() && float(gid.y) > menuHeight) {
            changed = any(fabs(previous.read(gid).rgb - current.read(gid).rgb) > float3(0.0390625f)) ? 1u : 0u;
        }
        // All lanes participate, including partial edge groups. Accumulate one
        // exact subtotal per SIMD group instead of contending once per pixel.
        uint subtotal = simd_sum(changed);
        if (lane == 0 && subtotal != 0) atomic_fetch_add_explicit(&count, subtotal, memory_order_relaxed);
    }
    """
    private struct DisplayState {
        var previous: Surface
        var spare: Surface?
        let menuHeight: Float
    }
    private let textureCache: CVMetalTextureCache
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let countBuffer: MTLBuffer
    private var displays: [CGDirectDisplayID: DisplayState] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalScreenDifferError.allocation }
        textureCache = cache
        guard let queue = device.makeCommandQueue(),
              let countBuffer = device.makeBuffer(length: 4, options: .storageModeShared) else {
            throw MetalScreenDifferError.allocation
        }
        self.queue = queue
        self.countBuffer = countBuffer
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "captureDiff") else {
            throw MetalScreenDifferError.commandEncoding
        }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// A retained CGContext draws into a shared Metal buffer. Two surfaces per
    /// display alternate only after successful GPU completion; no per-frame
    /// array allocation, zero-fill, or replaceRegion texture upload is needed.
    private final class Surface {
        let buffer: MTLBuffer?
        let texture: MTLTexture
        let context: CGContext?
        let capturedBuffer: CVPixelBuffer?
        let capturedTexture: CVMetalTexture?

        init(pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) throws {
            var wrapped: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer,
                [kCVMetalTextureUsage: MTLTextureUsage.shaderRead.rawValue] as CFDictionary,
                .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer),
                CVPixelBufferGetHeight(pixelBuffer), 0, &wrapped) == kCVReturnSuccess,
                let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else {
                throw MetalScreenDifferError.allocation
            }
            self.texture = texture
            capturedBuffer = pixelBuffer
            capturedTexture = wrapped
            buffer = nil
            context = nil
        }

        init(device: MTLDevice, width: Int, height: Int) throws {
            let alignment = max(64, device.minimumLinearTextureAlignment(for: .bgra8Unorm))
            let rowBytes = ((width * 4 + alignment - 1) / alignment) * alignment
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                  let context = CGContext(data: buffer.contents(), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw MetalScreenDifferError.allocation
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: rowBytes) else {
                throw MetalScreenDifferError.allocation
            }
            capturedBuffer = nil
            capturedTexture = nil
            self.buffer = buffer
            self.texture = texture
            self.context = context
            // Copy preserves premultiplied channels and overwrites transparent
            // pixels too; source-over would retain content from the spare frame.
            context.setBlendMode(.copy)
        }

        func draw(_ image: CGImage) {
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context?.flush()
        }
    }

    func process(_ frame: CapturedScreenFrame) throws -> ScreenDifferenceDecision {
        let signposter = CaptureDiffInstrumentation.signposter
        let width = frame.image.width, height = frame.image.height
        var menuHeight = CaptureContract.menuBarHeightPixels(backingScaleFactor: frame.backingScaleFactor)
        let prior = displays[frame.displayID]
        if prior == nil {
            let space = frame.image.colorSpace?.name as String? ?? "unknown"
            signposter.emitEvent("CaptureFormat", "width: \(width) height: \(height) bits: \(frame.image.bitsPerComponent) colorSpace: \(space, privacy: .public)")
        }
        let matches = prior.map {
            $0.previous.texture.width == width && $0.previous.texture.height == height
                && $0.menuHeight == menuHeight
        } ?? false
        let current: Surface
        let conversion = signposter.beginInterval("Canonicalize", id: signposter.makeSignpostID())
        if let buffer = frame.pixelBuffer,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetIOSurface(buffer) != nil {
            current = try Surface(pixelBuffer: buffer, cache: textureCache)
            signposter.emitEvent("NativeCaptureSurface")
        } else {
            if matches, let spare = prior?.spare { current = spare }
            else { current = try Surface(device: device, width: width, height: height) }
            current.draw(frame.image)
        }
        signposter.endInterval("Canonicalize", conversion)
        guard matches, let prior else {
            displays[frame.displayID] = DisplayState(previous: current,
                spare: nil, menuHeight: menuHeight)
            return ScreenDifferenceDecision(changedPixels: 0, isFirstFrame: true, admitted: true)
        }
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw MetalScreenDifferError.commandEncoding
        }
        command.label = "Capture diff"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(prior.previous.texture, index: 0)
        encoder.setTexture(current.texture, index: 1)
        encoder.setBuffer(countBuffer, offset: 0, index: 0)
        encoder.setBytes(&menuHeight, length: 4, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16,
            height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        let wait = signposter.beginInterval("GPUWait", id: signposter.makeSignpostID())
        command.commit()
        command.waitUntilCompleted()
        signposter.endInterval("GPUWait", wait)
        guard command.status == .completed else {
            throw MetalScreenDifferError.execution(command.error?.localizedDescription ?? "GPU command failed")
        }
        signposter.emitEvent("GPUTime", "milliseconds: \(1000 * (command.gpuEndTime - command.gpuStartTime))")
        let count = Int(countBuffer.contents().load(as: UInt32.self))
        displays[frame.displayID] = DisplayState(previous: current, spare: prior.previous.context != nil ? prior.previous : nil, menuHeight: menuHeight)
        return ScreenDifferenceDecision(changedPixels: count, isFirstFrame: false,
                                        admitted: CaptureAdmissionPolicy.admits(changedPixels: count))
    }
}
#endif
