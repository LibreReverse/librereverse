#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Security

public struct GoogleOAuthClientConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret?.nilIfEmpty
    }

    public static func downloadedDesktopClientJSON(
        _ data: Data
    ) throws -> GoogleOAuthClientConfiguration {
        struct Document: Decodable {
            struct Installed: Decodable {
                let client_id: String
                let client_secret: String?
            }
            let installed: Installed?
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw GoogleDriveConnectionError.invalidClientConfiguration
        }
        guard let installed = document.installed,
              !installed.client_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GoogleDriveConnectionError.invalidClientConfiguration
        }
        return GoogleOAuthClientConfiguration(
            clientID: installed.client_id,
            clientSecret: installed.client_secret
        )
    }

    public static func bundled(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GoogleOAuthClientConfiguration? {
        let environmentID = environment["LIBREREVERSE_GOOGLE_CLIENT_ID"]?.nilIfEmpty
            ?? getenv("LIBREREVERSE_GOOGLE_CLIENT_ID").map { String(cString: $0) }.flatMap(\.nilIfEmpty)
        let plistID = (infoDictionary["LibreReverseGoogleOAuthClientID"] as? String)?.nilIfEmpty
        guard let clientID = environmentID ?? plistID else { return nil }
        let environmentSecret = environment["LIBREREVERSE_GOOGLE_CLIENT_SECRET"]?.nilIfEmpty
            ?? getenv("LIBREREVERSE_GOOGLE_CLIENT_SECRET").map { String(cString: $0) }.flatMap(\.nilIfEmpty)
        let plistSecret = (infoDictionary["LibreReverseGoogleOAuthClientSecret"] as? String)?.nilIfEmpty
        return GoogleOAuthClientConfiguration(
            clientID: clientID,
            clientSecret: environmentSecret ?? plistSecret
        )
    }
}

public enum GoogleOAuthClientSource: String, Equatable, Sendable { case bundled }

public struct GoogleDriveConfigurationStatus: Equatable, Sendable {
    public let source: GoogleOAuthClientSource?
    public let hasSavedAuthorization: Bool

    public init(source: GoogleOAuthClientSource?, hasSavedAuthorization: Bool) {
        self.source = source
        self.hasSavedAuthorization = hasSavedAuthorization
    }
}

public struct GoogleDriveConnectionIdentity: Codable, Equatable, Sendable {
    public let displayName: String
    public let emailAddress: String
    public let permissionID: String
    public let rootFolderID: String
    public let storageUsage: Int64?
    public let storageLimit: Int64?

    public init(
        displayName: String,
        emailAddress: String,
        permissionID: String,
        rootFolderID: String,
        storageUsage: Int64?,
        storageLimit: Int64?
    ) {
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.permissionID = permissionID
        self.rootFolderID = rootFolderID
        self.storageUsage = storageUsage
        self.storageLimit = storageLimit
    }
}

public enum GoogleDriveConnectionError: Error, Equatable, LocalizedError, Sendable {
    case missingClientConfiguration
    case invalidClientConfiguration
    case unableToOpenBrowser
    case unableToCreateLoopbackListener(Int32)
    case authorizationTimedOut
    case invalidAuthorizationCallback
    case authorizationDenied(String)
    case stateMismatch
    case missingAuthorizationCode
    case tokenRequestFailed(status: Int, message: String)
    case invalidTokenResponse
    case missingRefreshToken
    case notAuthorized
    case driveRequestFailed(status: Int, message: String)
    case invalidDriveResponse
    case duplicateArchiveRoots

    public var errorDescription: String? {
        switch self {
        case .missingClientConfiguration:
            "Google Drive needs an OAuth desktop client configuration."
        case .invalidClientConfiguration:
            "That file is not a valid Google OAuth desktop client JSON file."
        case .unableToOpenBrowser:
            "Unable to open the Google authorization page."
        case let .unableToCreateLoopbackListener(status):
            "Unable to start the local OAuth callback listener (\(status))."
        case .authorizationTimedOut:
            "Google authorization timed out."
        case .invalidAuthorizationCallback:
            "The local Google authorization callback was invalid."
        case let .authorizationDenied(reason):
            "Google authorization was not completed: \(reason)"
        case .stateMismatch:
            "Google authorization returned an invalid security state."
        case .missingAuthorizationCode:
            "Google authorization did not return an authorization code."
        case let .tokenRequestFailed(status, message):
            "Google token exchange failed (HTTP \(status)): \(message)"
        case .invalidTokenResponse:
            "Google returned an invalid token response."
        case .missingRefreshToken:
            "Google did not return offline authorization. Disconnect and try again."
        case .notAuthorized:
            "Google Drive is not authorized."
        case let .driveRequestFailed(status, message):
            "Google Drive request failed (HTTP \(status)): \(message)"
        case .invalidDriveResponse:
            "Google Drive returned an invalid response."
        case .duplicateArchiveRoots:
            "Multiple LibreReverse storage folders were found in Google Drive."
        }
    }
}

public enum GoogleDriveOAuthContract {
    public static let authorizationEndpoint = URL(
        string: "https://accounts.google.com/o/oauth2/v2/auth"
    )!
    public static let tokenEndpoint = URL(
        string: "https://oauth2.googleapis.com/token"
    )!
    public static let revokeEndpoint = URL(
        string: "https://oauth2.googleapis.com/revoke"
    )!
    public static let driveScope = "https://www.googleapis.com/auth/drive.file"

    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public static func authorizationURL(
        configuration: GoogleOAuthClientConfiguration,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(
            url: authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: driveScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public static func randomURLSafeString(byteCount: Int = 48) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GoogleDriveConnectionError.unableToCreateLoopbackListener(status)
        }
        return Data(bytes).base64URLEncodedString()
    }
}

public struct GoogleOAuthCallback: Equatable, Sendable {
    public let code: String?
    public let state: String?
    public let error: String?

    public init(code: String?, state: String?, error: String?) {
        self.code = code
        self.state = state
        self.error = error
    }

    public static func parse(requestTarget: String) throws -> GoogleOAuthCallback {
        guard let components = URLComponents(string: "http://127.0.0.1\(requestTarget)"),
              components.path == "/oauth2/callback"
        else {
            throw GoogleDriveConnectionError.invalidAuthorizationCallback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        return GoogleOAuthCallback(
            code: values["code"]?.nilIfEmpty,
            state: values["state"]?.nilIfEmpty,
            error: values["error_description"]?.nilIfEmpty ?? values["error"]?.nilIfEmpty
        )
    }
}

public final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    public let port: UInt16
    public var redirectURI: String { "http://127.0.0.1:\(port)/oauth2/callback" }

    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    private var waiting = false

    public init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno)
        }
        var reuse: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0, listen(socketDescriptor, 1) == 0 else {
            let status = errno
            Darwin.close(socketDescriptor)
            throw GoogleDriveConnectionError.unableToCreateLoopbackListener(status)
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            let status = errno
            Darwin.close(socketDescriptor)
            throw GoogleDriveConnectionError.unableToCreateLoopbackListener(status)
        }
        descriptor = socketDescriptor
        port = UInt16(bigEndian: resolved.sin_port)
    }

    deinit { close() }

    public func waitForCallback(timeout: TimeInterval = 300) async throws -> GoogleOAuthCallback {
        let waiter = Task.detached(priority: .userInitiated) { [self] in
            try blockingWaitForCallback(timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let callback = try await waiter.value
            try Task.checkCancellation()
            return callback
        } onCancel: {
            waiter.cancel()
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func blockingWaitForCallback(timeout: TimeInterval) throws -> GoogleOAuthCallback {
        // Keep a private descriptor alive while polling. A concurrent close of
        // the public listener must never let us poll an unrelated reused fd.
        let listener: Int32 = try lock.withLock {
            guard !closed else { throw CancellationError() }
            guard !waiting else { throw GoogleDriveConnectionError.invalidAuthorizationCallback }
            let copy = Darwin.dup(descriptor)
            guard copy >= 0 else {
                throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno)
            }
            waiting = true
            return copy
        }
        defer {
            Darwin.close(listener)
            close()
        }
        guard timeout.isFinite, timeout > 0 else {
            throw GoogleDriveConnectionError.authorizationTimedOut
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        while true {
            try waitForReadable(listener, deadline: deadline)
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                try checkCallbackCancellation()
                throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno)
            }
            defer { Darwin.close(client) }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            let lineEnd = Data([13, 10])
            while request.range(of: lineEnd) == nil {
                try waitForReadable(client, deadline: deadline)
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.recv(client, &buffer, min(buffer.count, 16_384 - request.count), 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else {
                    throw GoogleDriveConnectionError.invalidAuthorizationCallback
                }
                request.append(contentsOf: buffer.prefix(count))
                guard request.count < 16_384 || request.range(of: lineEnd) != nil else {
                    throw GoogleDriveConnectionError.invalidAuthorizationCallback
                }
            }
            guard let end = request.range(of: lineEnd),
                  let firstLine = String(data: request[..<end.lowerBound], encoding: .utf8)
            else { throw GoogleDriveConnectionError.invalidAuthorizationCallback }
            let components = firstLine.split(separator: " ", maxSplits: 2)
            guard components.count == 3, components[0] == "GET" else {
                sendResponse(client, successful: false)
                throw GoogleDriveConnectionError.invalidAuthorizationCallback
            }
            let callback = try GoogleOAuthCallback.parse(requestTarget: String(components[1]))
            try checkCallbackCancellation()
            sendResponse(client, successful: callback.error == nil)
            return callback
        }
    }

    private func checkCallbackCancellation() throws {
        try Task.checkCancellation()
        if lock.withLock({ closed }) { throw CancellationError() }
    }

    private func waitForReadable(_ socket: Int32, deadline: TimeInterval) throws {
        while true {
            try checkCallbackCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw GoogleDriveConnectionError.authorizationTimedOut }
            var state = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(50, remaining * 1000)))
            let status = Darwin.poll(&state, 1, milliseconds)
            try checkCallbackCancellation()
            if status > 0 { return }
            if status < 0, errno != EINTR {
                throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno)
            }
        }
    }

    private func sendResponse(_ client: Int32, successful: Bool) {
        let title = successful
            ? "Authorization received"
            : "LibreReverse could not connect"
        let detail = successful
            ? "Return to LibreReverse while it verifies the Drive connection."
            : "Return to LibreReverse for details and try again."
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system;margin:48px;max-width:620px">
        <h1>\(title)</h1><p>\(detail)</p></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        response.withCString { pointer in
            _ = Darwin.send(client, pointer, strlen(pointer), 0)
        }
    }
}

public protocol GoogleDriveCredentialStore: Sendable {
    func data(account: String) throws -> Data?
    func set(_ data: Data, account: String) throws
    func remove(account: String) throws
}

public final class GoogleDriveEncryptedDatabaseStore: GoogleDriveCredentialStore, @unchecked Sendable {
    private let configuration: LibreReverseLibraryConfiguration

    public init(configuration: LibreReverseLibraryConfiguration) {
        self.configuration = configuration
    }

    public func data(account: String) throws -> Data? {
        try LibreReverseArchiveStore.credentialData(
            account: account,
            configuration: configuration
        )
    }

    public func set(_ data: Data, account: String) throws {
        try LibreReverseArchiveStore.setCredentialData(
            data,
            account: account,
            configuration: configuration
        )
    }

    public func remove(account: String) throws {
        try LibreReverseArchiveStore.removeCredentialData(
            account: account,
            configuration: configuration
        )
    }
}

public actor GoogleDriveConnectionManager {
    public typealias BrowserOpener = @MainActor @Sendable (URL) throws -> Void

    /// Validated authorization staged until the archive destination and credentials commit together.
    public struct PendingAuthorization: Sendable {
        public let identity: GoogleDriveConnectionIdentity
        public let credentialUpdates: [String: Data]
        fileprivate let accessToken: String
        fileprivate let expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
        let token_type: String?
    }

    private struct DriveAbout: Decodable {
        struct User: Decodable {
            let displayName: String
            let emailAddress: String
            let permissionId: String
        }
        struct Quota: Decodable {
            let usage: String?
            let limit: String?
        }
        let user: User
        let storageQuota: Quota?
    }

    private struct DriveFile: Codable {
        let id: String
        let name: String?
        let appProperties: [String: String]?
    }

    private struct DriveFileList: Decodable {
        let files: [DriveFile]
    }

    private let bundledConfiguration: GoogleOAuthClientConfiguration?
    private let session: URLSession
    private let credentialStore: any GoogleDriveCredentialStore
    private var cachedAccessToken: (value: String, expiresAt: Date)?

    public init(
        bundledConfiguration: GoogleOAuthClientConfiguration? = .bundled(),
        session: URLSession = .shared,
        credentialStore: any GoogleDriveCredentialStore
    ) {
        self.bundledConfiguration = bundledConfiguration
        self.session = session
        self.credentialStore = credentialStore
    }

    public func configurationStatus() throws -> GoogleDriveConfigurationStatus {
        guard let resolved = try resolvedConfiguration() else {
            return GoogleDriveConfigurationStatus(source: nil, hasSavedAuthorization: false)
        }
        return GoogleDriveConfigurationStatus(
            source: resolved.source,
            hasSavedAuthorization: try credentialStore.data(
                account: refreshTokenAccount(clientID: resolved.configuration.clientID)
            ) != nil
        )
    }

    public func savedConnectionIdentity() throws -> GoogleDriveConnectionIdentity? {
        guard let resolved = try resolvedConfiguration() else { return nil }
        guard let data = try credentialStore.data(
            account: connectionIdentityAccount(clientID: resolved.configuration.clientID)
        ) else { return nil }
        return try? JSONDecoder().decode(GoogleDriveConnectionIdentity.self, from: data)
    }

    public func connect(openBrowser: BrowserOpener) async throws -> GoogleDriveConnectionIdentity {
        let pending = try await authorize(openBrowser: openBrowser)
        for (account, data) in pending.credentialUpdates {
            try credentialStore.set(data, account: account)
        }
        acceptPersistedAuthorization(pending)
        return pending.identity
    }

    /// Performs OAuth and validates the account without replacing the active credentials or token.
    public func authorize(openBrowser: BrowserOpener) async throws -> PendingAuthorization {
        guard let resolved = try resolvedConfiguration() else {
            throw GoogleDriveConnectionError.missingClientConfiguration
        }
        let listener = try GoogleOAuthLoopbackServer()
        defer { listener.close() }
        let verifier = try GoogleDriveOAuthContract.randomURLSafeString()
        let state = try GoogleDriveOAuthContract.randomURLSafeString(byteCount: 32)
        let authorizationURL = GoogleDriveOAuthContract.authorizationURL(
            configuration: resolved.configuration,
            redirectURI: listener.redirectURI,
            state: state,
            codeChallenge: GoogleDriveOAuthContract.codeChallenge(for: verifier)
        )
        try await openBrowser(authorizationURL)
        let callback = try await listener.waitForCallback()
        if let error = callback.error {
            throw GoogleDriveConnectionError.authorizationDenied(error)
        }
        guard callback.state == state else {
            throw GoogleDriveConnectionError.stateMismatch
        }
        guard let code = callback.code else {
            throw GoogleDriveConnectionError.missingAuthorizationCode
        }
        let token = try await exchangeAuthorizationCode(
            code,
            verifier: verifier,
            redirectURI: listener.redirectURI,
            configuration: resolved.configuration
        )
        let expiresAt = Date().addingTimeInterval(TimeInterval(max(120, token.expires_in ?? 3_600)))
        let identity = try await validatedIdentity(accessToken: token.access_token)
        let account = refreshTokenAccount(clientID: resolved.configuration.clientID)
        let refreshToken: String?
        if let returned = token.refresh_token {
            refreshToken = returned
        } else if try savedConnectionIdentity()?.permissionID == identity.permissionID {
            refreshToken = try credentialStore.data(account: account).flatMap {
                String(data: $0, encoding: .utf8)
            }
        } else {
            refreshToken = nil
        }
        guard let refreshToken else {
            throw GoogleDriveConnectionError.missingRefreshToken
        }
        return PendingAuthorization(
            identity: identity,
            credentialUpdates: [
                account: Data(refreshToken.utf8),
                connectionIdentityAccount(clientID: resolved.configuration.clientID): try JSONEncoder().encode(identity),
            ],
            accessToken: token.access_token,
            expiresAt: expiresAt
        )
    }

    /// Call after atomically persisting the pending credentials with the selected destination.
    public func acceptPersistedAuthorization(_ pending: PendingAuthorization) {
        cachedAccessToken = (pending.accessToken, pending.expiresAt)
    }

    public func restore() async throws -> GoogleDriveConnectionIdentity? {
        guard let resolved = try resolvedConfiguration() else { return nil }
        let account = refreshTokenAccount(clientID: resolved.configuration.clientID)
        guard let refreshData = try credentialStore.data(account: account),
              let refreshToken = String(data: refreshData, encoding: .utf8)
        else { return nil }
        let token = try await refreshAccessToken(
            refreshToken,
            configuration: resolved.configuration
        )
        cacheAccessToken(token)
        return try await validateAndPersistIdentity(accessToken: token.access_token)
    }

    /// Verifies that the saved refresh credential can still mint an access
    /// token without changing the persisted connection record or touching
    /// Drive contents. Useful for read-only validation and reconnect UI.
    public func validateSavedAuthorizationToken() async throws {
        _ = try await validAccessToken()
    }

    public func disconnect() async throws {
        guard let resolved = try resolvedConfiguration() else { return }
        let account = refreshTokenAccount(clientID: resolved.configuration.clientID)
        if let data = try? credentialStore.data(account: account),
           let token = String(data: data, encoding: .utf8) {
            var request = URLRequest(url: GoogleDriveOAuthContract.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(["token": token])
            _ = try? await session.data(for: request)
        }
        try credentialStore.remove(account: account)
        try credentialStore.remove(
            account: connectionIdentityAccount(clientID: resolved.configuration.clientID)
        )
        cachedAccessToken = nil
    }

    /// Short-lived bearer token for the Drive archive adapter. Refresh tokens
    /// remain inside the encrypted library database and callers never log them.
    func validAccessToken() async throws -> String {
        if let cachedAccessToken,
           cachedAccessToken.expiresAt.timeIntervalSinceNow > 60 {
            return cachedAccessToken.value
        }
        guard let resolved = try resolvedConfiguration() else {
            throw GoogleDriveConnectionError.missingClientConfiguration
        }
        let account = refreshTokenAccount(clientID: resolved.configuration.clientID)
        guard let data = try credentialStore.data(account: account),
              let refreshToken = String(data: data, encoding: .utf8) else {
            throw GoogleDriveConnectionError.missingRefreshToken
        }
        let token = try await refreshAccessToken(refreshToken, configuration: resolved.configuration)
        cacheAccessToken(token)
        return token.access_token
    }

    func invalidateAccessToken() {
        cachedAccessToken = nil
    }

    private func cacheAccessToken(_ token: TokenResponse) {
        cachedAccessToken = (
            token.access_token,
            Date().addingTimeInterval(TimeInterval(max(120, token.expires_in ?? 3_600)))
        )
    }

    private func validateAndPersistIdentity(
        accessToken: String
    ) async throws -> GoogleDriveConnectionIdentity {
        let identity = try await validatedIdentity(accessToken: accessToken)
        try credentialStore.set(
            try JSONEncoder().encode(identity),
            account: connectionIdentityAccount(clientID: try currentClientID())
        )
        return identity
    }

    private func validatedIdentity(accessToken: String) async throws -> GoogleDriveConnectionIdentity {
        let about = try await driveAbout(accessToken: accessToken)
        let rootFolderID = try await ensureArchiveRoot(accessToken: accessToken)
        let identity = GoogleDriveConnectionIdentity(
            displayName: about.user.displayName,
            emailAddress: about.user.emailAddress,
            permissionID: about.user.permissionId,
            rootFolderID: rootFolderID,
            storageUsage: about.storageQuota?.usage.flatMap(Int64.init),
            storageLimit: about.storageQuota?.limit.flatMap(Int64.init)
        )
        return identity
    }

    private func driveAbout(accessToken: String) async throws -> DriveAbout {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "user(displayName,emailAddress,permissionId),storageQuota(limit,usage)"
            )
        ]
        return try await driveJSON(
            URLRequest(url: components.url!),
            accessToken: accessToken,
            as: DriveAbout.self
        )
    }

    private func ensureArchiveRoot(accessToken: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "mimeType='application/vnd.google-apps.folder' and trashed=false and \(GoogleDriveMetadata.query(.root, equals: "1"))"
            ),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "files(id,name,appProperties)"),
        ]
        let result: DriveFileList = try await driveJSON(
            URLRequest(url: components.url!),
            accessToken: accessToken,
            as: DriveFileList.self
        )
        if result.files.count > 1 { throw GoogleDriveConnectionError.duplicateArchiveRoots }
        if let existing = result.files.first {
            guard GoogleDriveMetadata.value(.root, in: existing.appProperties) == "1" else {
                throw GoogleDriveConnectionError.invalidDriveResponse
            }
            return existing.id
        }

        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,name,appProperties")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "LibreReverse",
            "mimeType": "application/vnd.google-apps.folder",
            "appProperties": [
                "librereverseRoot": "1",
                "librereverseSchema": "1",
            ],
        ])
        let created: DriveFile = try await driveJSON(
            request,
            accessToken: accessToken,
            as: DriveFile.self
        )
        return created.id
    }

    private func driveJSON<T: Decodable>(
        _ request: URLRequest,
        accessToken: String,
        as type: T.Type
    ) async throws -> T {
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveConnectionError.invalidDriveResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveConnectionError.driveRequestFailed(
                status: http.statusCode,
                message: googleErrorMessage(data)
            )
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleDriveConnectionError.invalidDriveResponse
        }
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        redirectURI: String,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> TokenResponse {
        var values = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = configuration.clientSecret { values["client_secret"] = secret }
        return try await tokenRequest(values)
    }

    private func refreshAccessToken(
        _ refreshToken: String,
        configuration: GoogleOAuthClientConfiguration
    ) async throws -> TokenResponse {
        var values = [
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = configuration.clientSecret { values["client_secret"] = secret }
        return try await tokenRequest(values)
    }

    private func tokenRequest(_ values: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleDriveOAuthContract.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(values)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveConnectionError.invalidTokenResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleDriveConnectionError.tokenRequestFailed(
                status: http.statusCode,
                message: googleErrorMessage(data)
            )
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleDriveConnectionError.invalidTokenResponse
        }
    }

    private func resolvedConfiguration() throws -> (
        configuration: GoogleOAuthClientConfiguration,
        source: GoogleOAuthClientSource
    )? {
        if let bundledConfiguration {
            return (bundledConfiguration, .bundled)
        }
        return nil
    }

    private func refreshTokenAccount(clientID: String) -> String {
        let digest = SHA256.hash(data: Data(clientID.utf8))
        return "refresh-token-" + Data(digest).base64URLEncodedString()
    }

    private func connectionIdentityAccount(clientID: String) -> String {
        let digest = SHA256.hash(data: Data(clientID.utf8))
        return "connection-identity-" + Data(digest).base64URLEncodedString()
    }

    private func currentClientID() throws -> String {
        guard let resolved = try resolvedConfiguration() else {
            throw GoogleDriveConnectionError.missingClientConfiguration
        }
        return resolved.configuration.clientID
    }

    private func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = values.keys.sorted().map { key in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let raw = values[key] ?? ""
            let encodedValue = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    private func googleErrorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "Unknown Google API error" }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let description = object["error_description"] as? String {
            return description
        }
        if let error = object["error"] as? String { return error }
        return "Unknown Google API error"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
