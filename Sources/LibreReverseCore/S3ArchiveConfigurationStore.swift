#if os(macOS)
import Foundation

/// Credentials live with the encrypted library, never in preferences or logs.
public struct S3ArchiveConfigurationStore: Sendable {
    private let library: LibreReverseLibraryConfiguration
    public static let credentialAccount = "archive.s3.configuration.v1"

    public init(library: LibreReverseLibraryConfiguration) { self.library = library }

    public func load() throws -> S3ArchiveConfiguration? {
        guard let data = try LibreReverseArchiveStore.credentialData(
            account: Self.credentialAccount, configuration: library) else { return nil }
        return try JSONDecoder().decode(S3ArchiveConfiguration.self, from: data)
    }

    public func save(_ configuration: S3ArchiveConfiguration) throws {
        try LibreReverseArchiveStore.setCredentialData(
            JSONEncoder().encode(configuration), account: Self.credentialAccount, configuration: library)
    }

    public func remove() throws {
        try LibreReverseArchiveStore.removeCredentialData(account: Self.credentialAccount, configuration: library)
    }

    /// A launcher may supply these variables; the app never reads shell files.
    public static func environmentConfiguration(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> S3ArchiveConfiguration? {
        guard let key = environment["S3_KEY"], !key.isEmpty,
              let secret = environment["S3_SECRET"], !secret.isEmpty,
              let address = environment["S3_URL"], let endpoint = URL(string: address),
              let bucket = environment["S3_BUCKET"], !bucket.isEmpty else { return nil }
        return try S3ArchiveConfiguration(endpoint: endpoint, bucket: bucket,
            region: environment["S3_REGION"] ?? "us-east-1", accessKey: key, secretKey: secret,
            sessionToken: environment["S3_SESSION_TOKEN"])
    }
}
#endif
