#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

final class StatusIconTests: XCTestCase {
    func testBrandLoopRemainsIdenticalAndPausedLoopDims() throws {
        func pixels(_ state: LibreReverseStatusIconState) throws -> [UInt8] {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 44, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = LibreReverseStatusIcon.pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            LibreReverseStatusIcon.image(for: state).draw(in: NSRect(origin: .zero, size: rep.size))
            NSGraphicsContext.restoreGraphicsState()
            let data = try XCTUnwrap(rep.bitmapData)
            // AppKit pads bitmap scanlines; compare only actual pixel bytes.
            return (0..<36).flatMap { row in
                Array(UnsafeBufferPointer(start: data + row * rep.bytesPerRow, count: 44 * 4))
            }
        }
        let normal = try pixels(.recording)
        for state in [LibreReverseStatusIconState.meetingRecording, .error] {
            let other = try pixels(state)
            for y in 0..<36 { for x in 0..<44 where hypot(Double(x) + 0.5 - 22, Double(y) + 0.5 - 18) > 11 {
                let index = (y * 44 + x) * 4 + 3
                XCTAssertEqual(normal[index], other[index], "The outer app mark must stay stable")
            }}
        }
        let paused = try pixels(.paused)
        var activeAlpha = 0, pausedAlpha = 0
        for y in 0..<36 { for x in 0..<44 where hypot(Double(x) + 0.5 - 22, Double(y) + 0.5 - 18) > 11 {
            let i = (y * 44 + x) * 4 + 3
            activeAlpha += Int(normal[i]); pausedAlpha += Int(paused[i])
            if normal[i] > 40 { XCTAssertGreaterThan(paused[i], 0, "Dimming must preserve the outer mark") }
            if normal[i] == 0 { XCTAssertEqual(paused[i], 0) }
        }}
        guard case .pause = LibreReverseStatusIconState.paused.centerCue else {
            return XCTFail("Paused capture must show pause bars")
        }
        XCTAssertEqual(Double(pausedAlpha) / Double(activeAlpha), 0.42, accuracy: 0.03)
    }

    func testEveryStateRendersDistinctStableAccessibleTemplate() throws {
        var renderedStates = Set<Data>()
        for state in LibreReverseStatusIconState.allCases {
            let image = LibreReverseStatusIcon.image(for: state)
            XCTAssertEqual(image.size, NSSize(width: 22, height: 18))
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.accessibilityDescription, "LibreReverse — \(state.statusDescription)")
            let representation = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 36,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            representation.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try XCTUnwrap(representation.bitmapData)
            XCTAssertTrue((0..<(44 * 36)).contains { pixels[$0 * 4 + 3] > 0 }, "Missing glyph: \(state)")
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            XCTAssertTrue(renderedStates.insert(data).inserted, "State must be visually distinct: \(state)")
            if let directory = ProcessInfo.processInfo.environment["LIBREREVERSE_STATUS_ICON_PREVIEW_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent("\(state).png"))
            }
        }
    }
}
#endif
