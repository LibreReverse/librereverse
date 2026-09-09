#if os(macOS)
import AppKit
import Foundation

/// Resolves website identity without sending browsing hosts to a third party.
///
/// The app reads its owned cache and bundled catalog.
/// Missing icons deliberately remain local and use a deterministic monogram in
/// the view without network requests.
@MainActor
final class LibreReverseFaviconResolver {
    static let shared = LibreReverseFaviconResolver()

    private let cacheRoot: URL?
    private let bundledRoot: URL?
    private let fileManager: FileManager
    private var memory: [String: NSImage] = [:]
    private var misses = Set<String>()

    init(
        cacheRoot: URL? = nil,
        bundledRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let cacheRoot {
            self.cacheRoot = cacheRoot
        } else if LibreReverseDevelopmentEnvironment.values[
            "LIBREREVERSE_DAILY_RECAP_UI_FIXTURE"
        ] != nil {
            self.cacheRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "LibreReverse-DailyRecap-Fixture-Favicons",
                isDirectory: true
            )
        } else {
            self.cacheRoot = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("LibreReverse/Favicons", isDirectory: true)
        }
        self.bundledRoot = bundledRoot
            ?? Bundle.main.resourceURL?.appendingPathComponent("Favicons", isDirectory: true)
    }

    func image(for host: String) -> NSImage? {
        for key in Self.assetKeys(for: host) {
            if let image = memory[key] { return image }
            if misses.contains(key) { continue }
            if let image = load(key: key) {
                memory[key] = image
                return image
            }
            misses.insert(key)
        }
        return nil
    }

    static func assetKeys(for host: String) -> [String] {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty,
            normalizedHost.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
            })
        else { return [] }
        var hosts = [normalizedHost]
        if normalizedHost.hasPrefix("www."), normalizedHost.count > 4 {
            hosts.append(String(normalizedHost.dropFirst(4)))
        }
        return hosts.map {
            $0.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
            }.joined()
        }
    }

    static func monogram(for host: String) -> String {
        let label = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
        guard let scalar = label.unicodeScalars.first,
            CharacterSet.alphanumerics.contains(scalar)
        else { return "?" }
        return String(scalar).uppercased()
    }

    static func hue(for host: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in host.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 360) / 360
    }

    private func load(key: String) -> NSImage? {
        if let cacheRoot, let image = image(at: cacheRoot, key: key) { return image }
        if let bundledRoot, let image = image(at: bundledRoot, key: key) { return image }
        return nil
    }

    private func image(at root: URL, key: String) -> NSImage? {
        let url = root.appendingPathComponent(key, isDirectory: false).appendingPathExtension("png")
        guard fileManager.isReadableFile(atPath: url.path),
            let image = NSImage(contentsOf: url),
            image.isValid
        else { return nil }
        return image
    }

}
#endif
