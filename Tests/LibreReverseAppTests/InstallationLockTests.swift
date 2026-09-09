#if os(macOS)
import Foundation
import XCTest
@testable import LibreReverseApp

final class InstallationLockTests: XCTestCase {
    func testExcludesConcurrentOwnersAndReleasesOnShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibreReverse-Lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: LibreReverseInstallationLock? = try LibreReverseInstallationLock(directory: root)
        XCTAssertNotNil(owner)
        XCTAssertThrowsError(try LibreReverseInstallationLock(directory: root))
        owner = nil
        let successor = try LibreReverseInstallationLock(directory: root)
        withExtendedLifetime(successor) {}
    }

    func testDoesNotFollowALockFileSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibreReverse-Lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("librereverse.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try LibreReverseInstallationLock(directory: root))
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
    }
}
#endif
