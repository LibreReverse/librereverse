import CryptoKit
import Foundation

/// Content-free URL classes retained by live meeting-detection evidence.
/// Meeting codes, tenant names, query strings, and full URLs never cross this
/// diagnostic boundary.
public enum LibreReverseMeetingProbeURLKind: String, Codable, Equatable, Sendable {
    case none
    case youtube
    case googleMeet
    case microsoftTeams
    case slackHuddle
    case zoom
    case other

    public init(url: URL?) {
        guard let url, let host = url.host?.lowercased() else {
            self = .none
            return
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be")
        {
            self = .youtube
        } else if host == "meet.google.com" {
            self = .googleMeet
        } else if host == "teams.microsoft.com" || host == "teams.live.com" {
            self = .microsoftTeams
        } else if host == "app.slack.com" {
            self = .slackHuddle
        } else if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            self = .zoom
        } else {
            self = .other
        }
    }
}

public struct LibreReverseMeetingProbeObservation: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let bundleIdentifier: String
    public let hasTitle: Bool
    public let titleLength: Int
    public let urlKind: LibreReverseMeetingProbeURLKind
    public let accessibilityMarkers: [String]
    public let usesMicrophoneInput: Bool

    public init(_ observation: LibreReverseMeetingWindowObservation) {
        windowID = observation.windowID
        bundleIdentifier = observation.bundleIdentifier
        hasTitle = !observation.title.isEmpty
        titleLength = observation.title.count
        urlKind = .init(url: observation.url)
        accessibilityMarkers = LibreReverseMeetingDetector.canonicalAccessibilityMarkers.filter(
            Set(observation.accessibilityLabels).contains
        )
        usesMicrophoneInput = observation.usesMicrophoneInput
    }
}

public struct LibreReverseMeetingProbeCandidate: Codable, Equatable, Sendable {
    public let provider: LibreReverseMeetingProvider
    public let source: LibreReverseMeetingCandidateSource
    public let windowID: UInt32?
    public let bundleIdentifier: String?
    public let isBrowserMeeting: Bool
    public let usedURLlessMicrophoneFallback: Bool
    /// HMAC of the production logical-meeting key under an ephemeral per-run
    /// secret. Equality is meaningful only inside one probe trace; the room or
    /// process identity cannot be recovered from the evidence bundle.
    public let logicalMeetingToken: String

    public init(
        _ candidate: LibreReverseMeetingCandidate,
        usedURLlessMicrophoneFallback: Bool = false,
        logicalMeetingToken: String
    ) {
        provider = candidate.provider
        source = candidate.source
        windowID = candidate.windowID
        bundleIdentifier = candidate.bundleIdentifier
        isBrowserMeeting = candidate.isBrowserMeeting
        self.usedURLlessMicrophoneFallback = usedURLlessMicrophoneFallback
        self.logicalMeetingToken = logicalMeetingToken
    }
}

/// Content-free projection of the production lifecycle reducer. The probe
/// advances a dedicated reducer but never acknowledges prompts, starts capture,
/// or invokes any product side effect.
public enum LibreReverseMeetingProbeLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case candidate
    case prompt
    case starting
    case recording
    case ending
    case stopping
    case completed
    case failed
}

public enum LibreReverseMeetingProbeLifecycleCommand: String, Codable, Equatable, Sendable {
    case none
    case presentPrompt
    case dismissPrompt
    case startCapture
    case stopCapture
}

public struct LibreReverseMeetingProbeLifecycleStep: Equatable, Sendable {
    public let state: LibreReverseMeetingLifecycleState
    public let command: LibreReverseMeetingLifecycleCommand
}

/// Advances only the pure production reducer. Optional acknowledgements model
/// a successful capture boundary after the corresponding step has been
/// returned for evidence, but have no callback or dependency capable of
/// launching ScreenCaptureKit, a writer, persistence, or UI.
public struct LibreReverseMeetingProbeLifecycleSimulator: Sendable {
    public let configuration: LibreReverseMeetingLifecycleConfiguration
    public let simulatesCaptureAcknowledgements: Bool
    private var coordinator: LibreReverseMeetingLifecycleCoordinator

    public init(
        configuration: LibreReverseMeetingLifecycleConfiguration = .init(),
        simulatesCaptureAcknowledgements: Bool = false
    ) {
        self.configuration = configuration
        self.simulatesCaptureAcknowledgements = simulatesCaptureAcknowledgements
        coordinator = LibreReverseMeetingLifecycleCoordinator(configuration: configuration)
    }

    public mutating func step(
        candidates: [LibreReverseMeetingCandidate],
        at date: Date
    ) -> LibreReverseMeetingProbeLifecycleStep {
        let command = coordinator.observe(candidates, at: date)
        let step = LibreReverseMeetingProbeLifecycleStep(
            state: coordinator.state,
            command: command
        )
        guard simulatesCaptureAcknowledgements else { return step }
        switch command {
        case .startCapture:
            coordinator.captureDidStart(at: date)
        case .stopCapture:
            coordinator.captureDidFinish(segmentID: nil)
            coordinator.reset()
        case .none, .presentPrompt, .dismissPrompt:
            break
        }
        return step
    }
}

public struct LibreReverseMeetingDetectionProbeRecord: Codable, Equatable, Sendable {
    public let recordedAt: Date
    public let pollIndex: Int
    public let observations: [LibreReverseMeetingProbeObservation]
    public let candidates: [LibreReverseMeetingProbeCandidate]
    public let admissionCandidate: LibreReverseMeetingProbeCandidate?
    public let candidateSetAmbiguous: Bool
    public let dryRunLifecycleState: LibreReverseMeetingProbeLifecycleState
    public let dryRunLifecycleCommand: LibreReverseMeetingProbeLifecycleCommand
    public let dryRunLifecycleMeetingToken: String?
    public let collectionFailed: Bool

    public init(
        recordedAt: Date,
        pollIndex: Int,
        observations: [LibreReverseMeetingWindowObservation],
        candidates: [LibreReverseMeetingCandidate],
        identitySecret: Data? = nil,
        dryRunLifecycleState: LibreReverseMeetingLifecycleState = .idle,
        dryRunLifecycleCommand: LibreReverseMeetingLifecycleCommand = .none,
        collectionFailed: Bool = false
    ) {
        self.recordedAt = recordedAt
        self.pollIndex = pollIndex
        self.observations =
            observations
            .filter { Self.relevantBundleIdentifiers.contains($0.bundleIdentifier)
                || LibreReverseMeetingDetector.supportsNativeApplication(bundleIdentifier: $0.bundleIdentifier, applicationName: $0.applicationName) }
            .map(LibreReverseMeetingProbeObservation.init)
        let identitySecret = identitySecret ?? Self.makeEphemeralIdentitySecret()
        func redactedCandidate(
            _ candidate: LibreReverseMeetingCandidate
        ) -> LibreReverseMeetingProbeCandidate {
            let sourceObservation = observations.first { observation in
                observation.windowID == candidate.windowID
                    && observation.processIdentifier == candidate.processIdentifier
                    && observation.bundleIdentifier == candidate.bundleIdentifier
            }
            let usedURLlessMicrophoneFallback =
                candidate.provider == .googleMeet
                && candidate.isBrowserMeeting
                && sourceObservation?.url == nil
                && sourceObservation?.usesMicrophoneInput == true
                && LibreReverseMeetingProbeURLKind(url: candidate.url) == .googleMeet
            return LibreReverseMeetingProbeCandidate(
                candidate,
                usedURLlessMicrophoneFallback: usedURLlessMicrophoneFallback,
                logicalMeetingToken: Self.logicalMeetingToken(
                    for: candidate,
                    secret: identitySecret
                )
            )
        }
        self.candidates = candidates.map(redactedCandidate)
        let admission = LibreReverseMeetingCandidateArbitration.selectUnambiguous(candidates)
        admissionCandidate = admission.map(redactedCandidate)
        candidateSetAmbiguous = !candidates.isEmpty && admission == nil
        self.dryRunLifecycleState = Self.redactedLifecycleState(dryRunLifecycleState)
        self.dryRunLifecycleCommand = Self.redactedLifecycleCommand(dryRunLifecycleCommand)
        dryRunLifecycleMeetingToken = Self.lifecycleCandidate(dryRunLifecycleState).map {
            Self.logicalMeetingToken(for: $0, secret: identitySecret)
        }
        self.collectionFailed = collectionFailed
    }

    private static let relevantBundleIdentifiers =
        LibreReverseMeetingDetector.supportedBrowserBundleIdentifiers.union([
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.tinyspeck.slackmacgap",
            "com.webex.meetingmanager",
        ])

    public static func makeEphemeralIdentitySecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        )
    }

    private static func logicalMeetingToken(
        for candidate: LibreReverseMeetingCandidate,
        secret: Data
    ) -> String {
        let key = SymmetricKey(data: secret)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(
                LibreReverseMeetingCandidateArbitration.logicalMeetingKey(candidate).utf8
            ),
            using: key
        )
        return authentication.map { String(format: "%02x", $0) }.joined()
    }

    private static func redactedLifecycleState(
        _ state: LibreReverseMeetingLifecycleState
    ) -> LibreReverseMeetingProbeLifecycleState {
        switch state {
        case .idle: .idle
        case .candidate: .candidate
        case .prompt: .prompt
        case .starting: .starting
        case .recording: .recording
        case .ending: .ending
        case .stopping: .stopping
        case .completed: .completed
        case .failed: .failed
        }
    }

    private static func redactedLifecycleCommand(
        _ command: LibreReverseMeetingLifecycleCommand
    ) -> LibreReverseMeetingProbeLifecycleCommand {
        switch command {
        case .none: .none
        case .presentPrompt: .presentPrompt
        case .dismissPrompt: .dismissPrompt
        case .startCapture: .startCapture
        case .stopCapture: .stopCapture
        }
    }

    private static func lifecycleCandidate(
        _ state: LibreReverseMeetingLifecycleState
    ) -> LibreReverseMeetingCandidate? {
        switch state {
        case .idle:
            nil
        case .candidate(let candidate, _), .prompt(let candidate),
            .starting(let candidate), .recording(let candidate, _),
            .ending(let candidate, _, _, _), .stopping(let candidate, _),
            .completed(let candidate, _):
            candidate
        case .failed(let candidate, _):
            candidate
        }
    }
}
