import XCTest
@testable import LibreReverseCore

final class PermissionGrantContractTests: XCTestCase {
    typealias Contract = PermissionGrantContract

    func testBothRequiredPermissionsGateStartupRegardlessOfMicrophone() {
        for microphone in [false, true] {
            for accessibility in [false, true] {
                for screen in [false, true] {
                    let state = Contract.PublishedState(accessibility: accessibility, screenCapture: screen, microphone: microphone)
                    XCTAssertEqual(state.allRequiredPermissionsGranted, accessibility && screen)
                }
            }
        }
    }

    func testLastRequiredGrantStartsOnceWithoutWaitingForMicrophone() {
        var progress = Contract.SetupProgress(startWhenReady: true)
        XCTAssertFalse(progress.shouldStart(permissions: .init(accessibility: false, screenCapture: false, microphone: false)))
        XCTAssertFalse(progress.shouldStart(permissions: .init(accessibility: false, screenCapture: true, microphone: false)))
        XCTAssertTrue(progress.shouldStart(permissions: .init(accessibility: true, screenCapture: true, microphone: false)))
        XCTAssertFalse(progress.startPending)
        for microphone in [false, true, false] {
            XCTAssertFalse(progress.shouldStart(permissions: .init(accessibility: true, screenCapture: true, microphone: microphone)))
        }
    }

    func testOpeningSettingsDoesNotResumeAnExplicitlyPausedRecording() {
        var progress = Contract.SetupProgress(startWhenReady: false)
        XCTAssertFalse(progress.shouldStart(permissions: .init(accessibility: true, screenCapture: true, microphone: true)))
    }
}
