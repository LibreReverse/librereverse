#if os(macOS)
import AppKit
import CoreImage
import Foundation

public struct ApplicationMetadata {
    public let id: String
    public let color: NSColor?
    public let icon: NSImage?
    public let name: String?
    public let isMeetingApp: Bool
}

public enum ApplicationMetadataContract {
    public static let meetingBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.webex.meetingmanager",
    ]

    public static func name(
        suppliedName: String?,
        bundleName: String?,
        bundleIdentifier: String
    ) -> String? {
        if let suppliedName { return suppliedName }
        guard let bundleName, bundleName != bundleIdentifier else { return nil }
        return bundleName
    }

    public static func isMeetingApp(bundleIdentifier: String) -> Bool {
        meetingBundleIdentifiers.contains(bundleIdentifier)
    }
}

public enum ApplicationIconColorExtractor {
    /// Derives an application accent color: render
    /// CIAreaAverage into one RGBA8 pixel with a null working color space,
    /// create an opaque generic-RGB color, then preserve its hue/alpha while
    /// forcing saturation to 1 and brightness to 0.7.
    public static func color(for image: NSImage) -> NSColor {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            return .gray
        }

        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return .gray }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return .gray }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        pixel.withUnsafeMutableBytes { bytes in
            context.render(
                output,
                toBitmap: bytes.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )
        }
        guard let sampled = NSColor(cgColor: CGColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )) else {
            return .gray
        }
        return replacingComponents(
            of: sampled,
            saturation: 1,
            brightness: 0.7
        )
    }

    public static func opaque(_ color: NSColor) -> NSColor {
        replacingComponents(of: color, alpha: 1)
    }

    private static func replacingComponents(
        of color: NSColor,
        saturation: CGFloat? = nil,
        brightness: CGFloat? = nil,
        alpha: CGFloat? = nil
    ) -> NSColor {
        guard color.colorSpace.numberOfColorComponents >= 3 else {
            return color
        }
        var hue: CGFloat = 0
        var oldSaturation: CGFloat = 0
        var oldBrightness: CGFloat = 0
        var oldAlpha: CGFloat = 0
        color.getHue(
            &hue,
            saturation: &oldSaturation,
            brightness: &oldBrightness,
            alpha: &oldAlpha
        )
        return NSColor(
            calibratedHue: hue,
            saturation: saturation ?? oldSaturation,
            brightness: brightness ?? oldBrightness,
            alpha: alpha ?? oldAlpha
        )
    }
}

@MainActor
public final class ApplicationMetadataProvider {
    public static let shared = ApplicationMetadataProvider()

    public typealias ApplicationURLResolver = (String) -> URL?
    public typealias ApplicationIconResolver = (URL) -> NSImage
    public typealias BundleNameResolver = (URL) -> String?
    public typealias ColorResolver = (NSImage) -> NSColor

    private let applicationURL: ApplicationURLResolver
    private let applicationIcon: ApplicationIconResolver
    private let bundleName: BundleNameResolver
    private let color: ColorResolver
    private var cache: [String: ApplicationMetadata] = [:]

    public init(
        applicationURL: @escaping ApplicationURLResolver = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationIcon: @escaping ApplicationIconResolver = {
            NSWorkspace.shared.icon(forFile: $0.path)
        },
        bundleName: @escaping BundleNameResolver = {
            Bundle(url: $0)?.infoDictionary?[kCFBundleNameKey as String] as? String
        },
        color: @escaping ColorResolver = {
            ApplicationIconColorExtractor.color(for: $0)
        }
    ) {
        self.applicationURL = applicationURL
        self.applicationIcon = applicationIcon
        self.bundleName = bundleName
        self.color = color
    }

    public func metadata(
        bundleIdentifier: String,
        suppliedName: String? = nil
    ) -> ApplicationMetadata {
        if let cached = cache[bundleIdentifier] { return cached }

        let url = applicationURL(bundleIdentifier)
        let icon = url.map(applicationIcon)
        let resolvedName: String?
        if let suppliedName {
            resolvedName = suppliedName
        } else {
            resolvedName = ApplicationMetadataContract.name(
                suppliedName: nil,
                bundleName: url.flatMap(bundleName),
                bundleIdentifier: bundleIdentifier
            )
        }
        let metadata = ApplicationMetadata(
            id: bundleIdentifier,
            color: icon.map(color),
            icon: icon,
            name: resolvedName,
            isMeetingApp: ApplicationMetadataContract.isMeetingApp(
                bundleIdentifier: bundleIdentifier
            )
        )
        cache[bundleIdentifier] = metadata
        return metadata
    }
}
#endif
