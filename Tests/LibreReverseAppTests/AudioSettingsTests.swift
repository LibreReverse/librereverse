#if os(macOS)
import AppKit
import XCTest
@testable import LibreReverseApp

@MainActor
final class AudioSettingsTests: XCTestCase {
    func testRecoveredLanguageCatalogHasAutomaticPlusExactly57UniqueLanguages() {
        let languages = LibreReverseTranscriptionLanguage.supported
        XCTAssertEqual(languages.count, 58)
        XCTAssertNil(languages.first?.code)
        XCTAssertEqual(languages.first?.name, "Detect automatically")
        let codes = languages.compactMap(\.code)
        XCTAssertEqual(codes.count, 57)
        XCTAssertEqual(Set(codes).count, 57)
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("zh"))
        XCTAssertTrue(codes.contains("uk"))
        XCTAssertEqual(LibreReverseTranscriptionLanguage.normalizedCode("fr"), "fr")
        XCTAssertEqual(LibreReverseTranscriptionLanguage.normalizedCode("unknown"), "en")
        XCTAssertNil(LibreReverseTranscriptionLanguage.normalizedCode(""))
    }

    func testAudioControllerExposesSourceDeviceLanguageAndRecoveryStates() {
        let controller = LibreReverseAudioSettingsViewController(
            snapshot: {
                .init(
                    preferences: .init(
                        capturesSystemAudio: true,
                        capturesMicrophone: true,
                        microphoneDeviceID: "studio"
                    ),
                    microphoneAuthorized: true,
                    nativeMicrophoneCaptureSupported: true,
                    inputDevices: [
                        .init(id: "mac", name: "MacBook Microphone", isDefault: true),
                        .init(id: "studio", name: "Studio Microphone", isDefault: false),
                    ],
                    isRecording: false,
                    transcriptionLanguageCode: "en",
                    transcriptionBackendAvailable: true
                )
            },
            updatePreferences: { _ in },
            updateTranscriptionLanguage: { _ in },
            openMicrophonePrivacy: {}
        )
        let values = textValues(in: controller.view)
        XCTAssertTrue(values.contains("Audio capture source:"))
        XCTAssertTrue(values.contains("Microphone input:"))
        XCTAssertTrue(values.contains("Transcription language:"))
        XCTAssertTrue(values.contains(where: { $0.contains("DRM-protected") }))
        XCTAssertTrue(values.contains(where: { $0.contains("Bluetooth") }))
    }

    private func textValues(in root: NSView) -> [String] {
        var result: [String] = []
        if let field = root as? NSTextField { result.append(field.stringValue) }
        if let button = root as? NSButton { result.append(button.title) }
        if let popup = root as? NSPopUpButton {
            result.append(contentsOf: popup.itemTitles)
        }
        for child in root.subviews { result.append(contentsOf: textValues(in: child)) }
        return result
    }
}
#endif
