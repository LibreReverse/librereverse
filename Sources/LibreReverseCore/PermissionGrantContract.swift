import Foundation

/// Required access and the one-shot transition from setup to recording.
public enum PermissionGrantContract {
    public struct PublishedState: Equatable, Sendable {
        public var accessibility: Bool
        public var screenCapture: Bool
        public var microphone: Bool

        public init(accessibility: Bool, screenCapture: Bool, microphone: Bool) {
            self.accessibility = accessibility
            self.screenCapture = screenCapture
            self.microphone = microphone
        }

        public var allRequiredPermissionsGranted: Bool {
            accessibility && screenCapture
        }
    }

    public enum RecordingStatus: Equatable, Sendable {
        case waiting, starting, recording, paused
        case failed(String)
    }

    public struct SetupProgress: Sendable {
        public private(set) var startPending: Bool

        public init(startWhenReady: Bool) {
            startPending = startWhenReady
        }

        /// Consume the pending start before invoking the recording callback.
        /// Microphone changes and repeated refreshes cannot start capture twice.
        public mutating func shouldStart(permissions: PublishedState) -> Bool {
            guard startPending, permissions.allRequiredPermissionsGranted else { return false }
            startPending = false
            return true
        }
    }
}
