import Foundation

public enum CaptureAdmissionPolicy {
    public static let minimumChangedPixels = 1_000

    public static func admits(changedPixels: Int) -> Bool {
        changedPixels >= minimumChangedPixels
    }
}

public enum WriterContract {
    public static func averageBitRate(width: Int, height: Int, frameRate: Int32) -> UInt? {
        guard frameRate == 30, width > 0, height > 0 else { return nil }
        let rate = Double(width) * Double(height) * Double(frameRate) * 0.06375
        guard rate.isFinite, rate < Double(UInt.max) else { return nil }
        return UInt(rate)
    }
}

public enum RecordingContract {
    public static let maximumFramesPerVideo = 150
    public static let deferredWriteIntervalSeconds: TimeInterval = 300
}
