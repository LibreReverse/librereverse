#if os(macOS)
import AppKit
import LibreReverseCore
import Testing

@Suite("Application metadata")
struct ApplicationMetadataTests {
    @Test("timeline meeting-app metadata excludes Slack")
    func meetingMembership() {
        #expect(ApplicationMetadataContract.isMeetingApp(bundleIdentifier: "us.zoom.xos"))
        #expect(
            ApplicationMetadataContract.isMeetingApp(
                bundleIdentifier: "com.microsoft.teams"))
        #expect(
            ApplicationMetadataContract.isMeetingApp(
                bundleIdentifier: "com.microsoft.teams2"))
        #expect(
            ApplicationMetadataContract.isMeetingApp(
                bundleIdentifier: "com.webex.meetingmanager"))
        #expect(
            !ApplicationMetadataContract.isMeetingApp(
                bundleIdentifier: "com.tinyspeck.slackmacgap"))
    }

    @Test("supplied name wins and bundle-ID fallback is suppressed")
    func nameFallback() {
        #expect(
            ApplicationMetadataContract.name(
                suppliedName: "Supplied",
                bundleName: "Bundle",
                bundleIdentifier: "example.id"
            ) == "Supplied")
        #expect(
            ApplicationMetadataContract.name(
                suppliedName: nil,
                bundleName: "Bundle",
                bundleIdentifier: "example.id"
            ) == "Bundle")
        #expect(
            ApplicationMetadataContract.name(
                suppliedName: nil,
                bundleName: "example.id",
                bundleIdentifier: "example.id"
            ) == nil)
    }

    @MainActor
    @Test("bundle-ID cache preserves the first miss")
    func cachePreservesFirstMiss() {
        var urlCalls = 0
        var bundleNameCalls = 0
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let provider = ApplicationMetadataProvider(
            applicationURL: { _ in
                urlCalls += 1
                return URL(fileURLWithPath: "/Applications/Test.app")
            },
            applicationIcon: { _ in image },
            bundleName: { _ in
                bundleNameCalls += 1
                return "Bundle Name"
            },
            color: { _ in .red }
        )
        let first = provider.metadata(bundleIdentifier: "example.id", suppliedName: "First")
        let second = provider.metadata(bundleIdentifier: "example.id", suppliedName: "Second")
        #expect(urlCalls == 1)
        #expect(bundleNameCalls == 0)
        #expect(first.name == "First")
        #expect(second.name == "First")
        #expect(first.icon === second.icon)
    }

    @Test("solid image color preserves hue and forces saturation and brightness")
    func exactColorTransform() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5).setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let color = ApplicationIconColorExtractor.color(for: image)
            .usingColorSpace(.genericRGB)
        let resolved = try #require(color)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #expect(abs(saturation - 1) < 0.001)
        #expect(abs(brightness - 0.7) < 0.001)
        #expect(abs(alpha - 1) < 0.001)
        let opaque = ApplicationIconColorExtractor.opaque(resolved)
        #expect(abs(opaque.alphaComponent - 1) < 0.001)
    }
}
#endif
