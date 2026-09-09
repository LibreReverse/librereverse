#if os(macOS)
import AppKit

enum LibreReverseStatusIconState: CaseIterable {
    case recording
    case paused
    case waiting
    case error
    case meetingStarting
    case meetingRecording
    case meetingFinishing

    var statusDescription: String {
        switch self {
        case .recording: "Screen recording"
        case .paused: "Screen recording paused"
        case .waiting: "Waiting to record"
        case .error: "Recording needs attention"
        case .meetingStarting: "Starting meeting recording"
        case .meetingRecording: "Recording meeting"
        case .meetingFinishing: "Saving meeting recording"
        }
    }

    var centerCue: LibreReverseStatusIcon.Cue {
        switch self {
        case .recording: .play
        case .paused: .pause
        case .waiting: .clock
        case .error: .attention
        case .meetingStarting, .meetingRecording: .waveform
        case .meetingFinishing: .check
        }
    }
}

/// The app's reverse-loop/play mark, with an integrated center state cue.
/// AppKit tints the monochrome template for the current menu bar appearance.
enum LibreReverseStatusIcon {
    enum Cue { case play, pause, clock, attention, waveform, check }
    static let pointSize = NSSize(width: 22, height: 18)

    static func image(for state: LibreReverseStatusIconState) -> NSImage {
        let mark = NSImage(size: pointSize, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let loop = NSBezierPath()
            loop.lineWidth = 1.55
            loop.lineCapStyle = .round
            loop.appendArc(withCenter: NSPoint(x: 11, y: 9), radius: 7,
                startAngle: -28, endAngle: 132, clockwise: false)
            // Leave visible negative space below the arrowhead even at 1×.
            loop.move(to: NSPoint(x: 11 + 7 * cos(CGFloat.pi * 174 / 180),
                y: 9 + 7 * sin(CGFloat.pi * 174 / 180)))
            loop.appendArc(withCenter: NSPoint(x: 11, y: 9), radius: 7,
                startAngle: 174, endAngle: 310, clockwise: false)
            loop.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 4.5, y: 12.7))
            arrow.line(to: NSPoint(x: 6.3, y: 16.3))
            arrow.line(to: NSPoint(x: 8.1, y: 12.9))
            arrow.close(); arrow.fill()
            let cue = NSBezierPath()
            cue.lineWidth = 1.25
            cue.lineCapStyle = .round
            cue.lineJoinStyle = .round
            switch state.centerCue {
            case .play:
                cue.move(to: NSPoint(x: 9.5, y: 6.2))
                cue.line(to: NSPoint(x: 14, y: 9))
                cue.line(to: NSPoint(x: 9.5, y: 11.8))
                cue.close(); cue.fill()
            case .pause:
                for x: CGFloat in [9, 11.5] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 6.2, width: 1.5, height: 5.6),
                        xRadius: 0.3, yRadius: 0.3).fill()
                }
            case .waveform:
                for (x, height): (CGFloat, CGFloat) in [(8.8, 3), (11, 6), (13.2, 4)] {
                    cue.move(to: NSPoint(x: x, y: 9 - height / 2))
                    cue.line(to: NSPoint(x: x, y: 9 + height / 2))
                }
                cue.stroke()
            case .clock:
                cue.move(to: NSPoint(x: 11, y: 12))
                cue.line(to: NSPoint(x: 11, y: 9))
                cue.line(to: NSPoint(x: 13.2, y: 8))
                cue.stroke()
            case .attention:
                cue.move(to: NSPoint(x: 11, y: 12))
                cue.line(to: NSPoint(x: 11, y: 8.7)); cue.stroke()
                NSBezierPath(ovalIn: NSRect(x: 10.3, y: 6, width: 1.4, height: 1.4)).fill()
            case .check:
                cue.move(to: NSPoint(x: 8.5, y: 9))
                cue.line(to: NSPoint(x: 10.4, y: 7))
                cue.line(to: NSPoint(x: 13.6, y: 11.5)); cue.stroke()
            }
            return true
        }
        let opacity: CGFloat = switch state {
        case .paused, .waiting, .meetingStarting: 0.42
        default: 1
        }
        let image = NSImage(size: pointSize, flipped: false) { rect in
            mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LibreReverse — \(state.statusDescription)"
        return image
    }
}
#endif
