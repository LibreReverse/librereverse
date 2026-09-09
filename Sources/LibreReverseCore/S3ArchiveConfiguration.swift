#if os(macOS)
import CryptoKit
import Foundation

public enum S3ArchiveError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String), invalidScope, objectTooLarge, invalidCheckpoint
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): "Invalid S3 configuration: \(reason)"
        case .invalidScope: "The S3 object belongs to a different library or destination."
        case .objectTooLarge: "S3 uploads support objects up to 5 TiB."
        case .invalidCheckpoint: "The S3 upload checkpoint is invalid for this destination."
        }
    }
}

public struct S3ArchiveConfiguration: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let bucket: String
    public let region: String
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String?

    public init(endpoint: URL, bucket: String, region: String = "us-east-1",
                accessKey: String, secretKey: String, sessionToken: String? = nil) throws {
        let normalized = try Self.endpointURL(endpoint.absoluteString)
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !bucket.isEmpty, bucket != ".", bucket != "..", bucket.unicodeScalars.allSatisfy(safe.contains),
              !region.isEmpty, region.unicodeScalars.allSatisfy(safe.contains),
              !accessKey.isEmpty, !secretKey.isEmpty,
              ![accessKey, secretKey, sessionToken ?? ""].contains(where: { $0.contains("\n") || $0.contains("\r") })
        else { throw S3ArchiveError.invalidConfiguration("Bucket, region and credentials must be valid and nonempty.") }
        self.endpoint = normalized; self.bucket = bucket; self.region = region
        self.accessKey = accessKey; self.secretKey = secretKey; self.sessionToken = sessionToken
    }

    /// Bare host names (including explicit ports) default to HTTPS.
    public static func endpointURL(_ text: String) throws -> URL {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !text.contains("\\") else { throw S3ArchiveError.invalidConfiguration("Invalid endpoint.") }
        let address = text.contains("://") ? text : "https://" + text
        guard let endpoint = URL(string: address) else { throw S3ArchiveError.invalidConfiguration("Invalid endpoint.") }
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw S3ArchiveError.invalidConfiguration("Use an HTTPS endpoint without credentials or query parameters.") }
        guard !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw S3ArchiveError.invalidConfiguration("Endpoint path cannot contain dot segments.") }
        parts.host = host.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let normalized = parts.url else { throw S3ArchiveError.invalidConfiguration("Invalid endpoint.") }
        return normalized
    }

    public var destinationIdentity: String {
        "s3:" + S3SignatureV4.hex(SHA256.hash(data: Data("\(endpoint.absoluteString)\n\(bucket)\n\(region)".utf8)))
    }
    public var displayName: String { "\(bucket) (\(endpoint.host ?? "S3"))" }
    private enum CodingKeys: String, CodingKey { case endpoint, bucket, region, accessKey, secretKey, sessionToken }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(URL.self, forKey: .endpoint), bucket: c.decode(String.self, forKey: .bucket),
                      region: c.decode(String.self, forKey: .region), accessKey: c.decode(String.self, forKey: .accessKey),
                      secretKey: c.decode(String.self, forKey: .secretKey), sessionToken: c.decodeIfPresent(String.self, forKey: .sessionToken))
    }
}
#endif
