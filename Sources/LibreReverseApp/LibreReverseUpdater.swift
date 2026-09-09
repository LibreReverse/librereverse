#if os(macOS)
import CryptoKit
import Foundation

struct LibreReverseUpdateConfiguration: Equatable, Sendable {
    let manifestURL: URL
    let publicKey: Data

    static func bundled(bundle: Bundle = .main) -> Self? {
        guard
            let rawURL = bundle.object(
                forInfoDictionaryKey: "LibreReverseUpdateManifestURL"
            ) as? String,
            let manifestURL = URL(string: rawURL),
            manifestURL.scheme?.lowercased() == "https",
            let rawKey = bundle.object(
                forInfoDictionaryKey: "LibreReverseUpdatePublicKey"
            ) as? String,
            let publicKey = Data(base64Encoded: rawKey),
            publicKey.count == 32
        else { return nil }
        return .init(manifestURL: manifestURL, publicKey: publicKey)
    }
}

struct LibreReverseUpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let releaseNotesURL: URL?
    let sha256: String
}

struct LibreReverseSignedUpdateEnvelope: Codable, Equatable, Sendable {
    let payload: String
    let signature: String
}

enum LibreReverseUpdateCheckResult: Equatable, Sendable {
    case current
    case available(LibreReverseUpdateManifest)
}

enum LibreReverseUpdateError: Error, LocalizedError, Equatable {
    case invalidResponse
    case invalidEnvelope
    case invalidSignature
    case invalidManifest
    case downloadIntegrityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The update server returned an invalid response."
        case .invalidEnvelope:
            "The update manifest could not be decoded."
        case .invalidSignature:
            "The update manifest signature is invalid. No update was opened."
        case .invalidManifest:
            "The signed update manifest contains unsafe or incomplete release data."
        case .downloadIntegrityMismatch:
            "The downloaded update does not match the signed SHA-256. It was discarded."
        }
    }
}

struct LibreReverseUpdateChecker: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    let configuration: LibreReverseUpdateConfiguration
    let currentBuild: Int
    var fetch: Fetch = { url in
        try await URLSession.shared.data(from: url)
    }

    func check() async throws -> LibreReverseUpdateCheckResult {
        let (data, response) = try await fetch(configuration.manifestURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LibreReverseUpdateError.invalidResponse
        }
        guard let envelope = try? JSONDecoder().decode(
            LibreReverseSignedUpdateEnvelope.self,
            from: data
        ), let payload = Data(base64Encoded: envelope.payload),
           let signature = Data(base64Encoded: envelope.signature) else {
            throw LibreReverseUpdateError.invalidEnvelope
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try .init(rawRepresentation: configuration.publicKey)
        } catch {
            throw LibreReverseUpdateError.invalidSignature
        }
        guard publicKey.isValidSignature(signature, for: payload) else {
            throw LibreReverseUpdateError.invalidSignature
        }
        guard let manifest = try? JSONDecoder().decode(
            LibreReverseUpdateManifest.self,
            from: payload
        ), manifest.build > 0,
           !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           manifest.downloadURL.scheme?.lowercased() == "https",
           manifest.releaseNotesURL?.scheme?.lowercased() == "https"
             || manifest.releaseNotesURL == nil,
           manifest.sha256.count == 64,
           manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw LibreReverseUpdateError.invalidManifest
        }
        return manifest.build > currentBuild ? .available(manifest) : .current
    }
}

struct LibreReverseUpdateDownloader: Sendable {
    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)

    var download: Download = { url in
        try await URLSession.shared.download(from: url)
    }

    func downloadAndVerify(
        _ manifest: LibreReverseUpdateManifest,
        destinationDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> URL {
        let (temporaryURL, response) = try await download(manifest.downloadURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw LibreReverseUpdateError.invalidResponse
        }
        let actualHash = try sha256(of: temporaryURL)
        guard actualHash.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw LibreReverseUpdateError.downloadIntegrityMismatch
        }
        let safeVersion = manifest.version.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-"
        }
        let destination = destinationDirectory.appendingPathComponent(
            "LibreReverse-\(String(safeVersion)).zip"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
