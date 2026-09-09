import Foundation

/// Sparse capture may resume when native recording ends, but the current
/// primary still owns the unpublished meeting until publication/recovery drains.
enum LibreReverseMeetingPersistenceAdmission {
    static func canReplacePrimary(
        hasMeetingSession: Bool,
        hasMeetingOperation: Bool,
        captureRecoveryInProgress: Bool
    ) -> Bool {
        !hasMeetingSession && !hasMeetingOperation && !captureRecoveryInProgress
    }
}
