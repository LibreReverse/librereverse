import Foundation

public struct LibreReverseMeetingAudioPreferences: Codable, Equatable, Sendable {
  public var capturesSystemAudio: Bool
  public var capturesMicrophone: Bool
  public var microphoneDeviceID: String?

  public init(
    capturesSystemAudio: Bool = true,
    capturesMicrophone: Bool = true,
    microphoneDeviceID: String? = nil
  ) {
    self.capturesSystemAudio = capturesSystemAudio
    self.capturesMicrophone = capturesMicrophone
    self.microphoneDeviceID =
      capturesMicrophone
      ? microphoneDeviceID.flatMap { $0.isEmpty ? nil : $0 }
      : nil
  }

  public func effectiveCaptureSelection(
    microphoneAuthorized: Bool,
    nativeMicrophoneCaptureSupported: Bool
  ) -> LibreReverseMeetingAudioCaptureSelection {
    let microphoneEnabled =
      capturesMicrophone
      && microphoneAuthorized
      && nativeMicrophoneCaptureSupported
    return .init(
      capturesSystemAudio: capturesSystemAudio,
      capturesMicrophone: microphoneEnabled,
      microphoneDeviceID: microphoneEnabled ? microphoneDeviceID : nil
    )
  }
}

public struct LibreReverseMeetingAudioCaptureSelection: Equatable, Sendable {
  public let capturesSystemAudio: Bool
  public let capturesMicrophone: Bool
  public let microphoneDeviceID: String?

  public init(
    capturesSystemAudio: Bool,
    capturesMicrophone: Bool,
    microphoneDeviceID: String?
  ) {
    self.capturesSystemAudio = capturesSystemAudio
    self.capturesMicrophone = capturesMicrophone
    self.microphoneDeviceID = microphoneDeviceID
  }

  public var capturesAnyAudio: Bool {
    capturesSystemAudio || capturesMicrophone
  }

  /// Permission and route changes are capture-file boundaries. ScreenCaptureKit
  /// cannot add or remove a microphone track on an active recording, and
  /// pretending otherwise leaves the visible source selection out of sync
  /// with the encoded MP4.
  public func requiresCaptureRestart(
    from active: LibreReverseMeetingAudioCaptureSelection
  ) -> Bool {
    self != active
  }
}

/// User-visible facts for an active meeting capture. Keeping this independent
/// from AppKit makes the recording disclosure and elapsed clock deterministic
/// even when the timeline is opened after capture has already started.
public struct LibreReverseMeetingRecordingPresentation: Equatable, Sendable {
  public let title: String
  public let audioDescription: String
  public let startedAt: Date

  public init(
    candidate: LibreReverseMeetingCandidate,
    selection: LibreReverseMeetingAudioCaptureSelection,
    microphoneName: String? = nil,
    startedAt: Date
  ) {
    let trimmedTitle =
      candidate.title?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? ""
    title =
      trimmedTitle.isEmpty
      ? (candidate.source == .manual ? "Ad hoc meeting" : "Meeting recording")
      : trimmedTitle
    let resolvedMicrophoneName = microphoneName?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).nilIfEmpty
    switch (selection.capturesSystemAudio, selection.capturesMicrophone) {
    case (true, true):
      audioDescription =
        resolvedMicrophoneName.map {
          "System audio + microphone · \($0)"
        } ?? "System audio + microphone"
    case (true, false):
      audioDescription = "System audio only"
    case (false, true):
      audioDescription =
        resolvedMicrophoneName.map {
          "Microphone only · \($0)"
        } ?? "Microphone only"
    case (false, false):
      audioDescription = "Video only"
    }
    self.startedAt = startedAt
  }

  public func elapsedDescription(at date: Date) -> String {
    let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
    let hours = elapsed / 3_600
    let minutes = (elapsed % 3_600) / 60
    let seconds = elapsed % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum LibreReverseMeetingAudioRuntimeDecision: Equatable, Sendable {
  case unchanged
  case restart(LibreReverseMeetingAudioCaptureSelection)
  case selectedMicrophoneUnavailable(String)
}

extension LibreReverseMeetingAudioPreferences {
  public func runtimeDecision(
    from active: LibreReverseMeetingAudioCaptureSelection,
    microphoneAuthorized: Bool,
    nativeMicrophoneCaptureSupported: Bool,
    availableMicrophoneDeviceIDs: Set<String>
  ) -> LibreReverseMeetingAudioRuntimeDecision {
    let desired = effectiveCaptureSelection(
      microphoneAuthorized: microphoneAuthorized,
      nativeMicrophoneCaptureSupported: nativeMicrophoneCaptureSupported
    )
    guard desired.requiresCaptureRestart(from: active) else { return .unchanged }
    if desired.capturesMicrophone,
      let selectedDeviceID = desired.microphoneDeviceID,
      !availableMicrophoneDeviceIDs.contains(selectedDeviceID)
    {
      return .selectedMicrophoneUnavailable(selectedDeviceID)
    }
    return .restart(desired)
  }
}
