import Foundation

public struct LibreReverseMeetingCaptureStorageGuard: Equatable, Sendable {
    public static let measuredBytesPerSecond: Int64 = 8 * 1_048_576
    public static let defaultSafetyMultiplier = 1.25
    public static let defaultMinimumFreeBytes: Int64 = 2 * 1_073_741_824

    public let minimumFreeBytes: Int64
    public let estimatedBytesPerSecond: Int64
    public let safetyMultiplier: Double

    public init(
        minimumFreeBytes: Int64 = Self.defaultMinimumFreeBytes,
        estimatedBytesPerSecond: Int64 = Self.measuredBytesPerSecond,
        safetyMultiplier: Double = Self.defaultSafetyMultiplier
    ) {
        self.minimumFreeBytes = max(1, minimumFreeBytes)
        self.estimatedBytesPerSecond = max(1, estimatedBytesPerSecond)
        self.safetyMultiplier = max(1, safetyMultiplier)
    }

    public func requiredFreeBytes(plannedDuration: TimeInterval? = nil) -> Int64 {
        guard let plannedDuration, plannedDuration > 0 else {
            return minimumFreeBytes
        }
        let durationRequirement = Double(estimatedBytesPerSecond)
            * plannedDuration
            * safetyMultiplier
        return max(
            minimumFreeBytes,
            durationRequirement >= Double(Int64.max)
                ? Int64.max
                : Int64(durationRequirement.rounded(.up))
        )
    }

    public func hasCapacity(
        availableBytes: Int64,
        plannedDuration: TimeInterval? = nil
    ) -> Bool {
        availableBytes >= requiredFreeBytes(plannedDuration: plannedDuration)
    }
}
