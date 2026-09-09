import Darwin
import XCTest
@testable import LibreReverseCore

final class GoogleDriveConnectionTests: XCTestCase {
    private final class MemoryCredentialStore: GoogleDriveCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        var snapshot: [String: Data] { lock.withLock { values } }

        func data(account: String) throws -> Data? {
            lock.withLock { values[account] }
        }

        func set(_ data: Data, account: String) throws {
            lock.withLock { values[account] = data }
        }

        func remove(account: String) throws {
            _ = lock.withLock { values.removeValue(forKey: account) }
        }
    }

    private final class MockGoogleURLProtocol: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        static var permissionID = "permission-1"
        static var folderExists = false
        static var tokenRequests = 0
        static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self.requests.append(request) }
            let url = request.url!
            let body: String
            if url.path == "/token" {
                let tokenRequest = Self.lock.withLock { () -> Int in
                    Self.tokenRequests += 1
                    return Self.tokenRequests
                }
                body = tokenRequest == 1
                    ? #"{"access_token":"access-one","expires_in":3600,"refresh_token":"refresh-one","token_type":"Bearer"}"#
                    : #"{"access_token":"access-two","expires_in":3600,"token_type":"Bearer"}"#
            } else if url.path == "/drive/v3/about" {
                let permissionID = Self.lock.withLock { Self.permissionID }
                body = #"{"user":{"displayName":"Test User","emailAddress":"test@example.com","permissionId":"\#(permissionID)"},"storageQuota":{"usage":"42","limit":"1000"}}"#
            } else if url.path == "/drive/v3/files", request.httpMethod == "POST" {
                Self.lock.withLock { Self.folderExists = true }
                body = #"{"id":"folder-1","name":"LibreReverse","appProperties":{"librereverseRoot":"1","librereverseSchema":"1"}}"#
            } else if url.path == "/drive/v3/files" {
                let exists = Self.lock.withLock { Self.folderExists }
                body = exists
                    ? #"{"files":[{"id":"folder-1","name":"LibreReverse","appProperties":{"librereverseRoot":"1"}}]}"#
                    : #"{"files":[]}"#
            } else if url.host == "oauth2.googleapis.com", url.path == "/revoke" {
                body = "{}"
            } else {
                XCTFail("Unexpected Google request: \(request)")
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testParsesDownloadedDesktopClientJSON() throws {
        let data = Data(#"{"installed":{"client_id":"desktop.apps.googleusercontent.com","client_secret":"secret"}}"#.utf8)
        XCTAssertEqual(
            try GoogleOAuthClientConfiguration.downloadedDesktopClientJSON(data),
            GoogleOAuthClientConfiguration(
                clientID: "desktop.apps.googleusercontent.com",
                clientSecret: "secret"
            )
        )
    }

    func testRejectsWebClientJSON() {
        let data = Data(#"{"web":{"client_id":"web.apps.googleusercontent.com"}}"#.utf8)
        XCTAssertThrowsError(
            try GoogleOAuthClientConfiguration.downloadedDesktopClientJSON(data)
        ) { error in
            XCTAssertEqual(error as? GoogleDriveConnectionError, .invalidClientConfiguration)
        }
    }

    func testBundledConfigurationPrefersBuildEnvironment() {
        let configuration = GoogleOAuthClientConfiguration.bundled(
            infoDictionary: [
                "LibreReverseGoogleOAuthClientID": "plist-id",
                "LibreReverseGoogleOAuthClientSecret": "plist-secret",
            ],
            environment: [
                "LIBREREVERSE_GOOGLE_CLIENT_ID": "environment-id",
                "LIBREREVERSE_GOOGLE_CLIENT_SECRET": "environment-secret",
            ]
        )
        XCTAssertEqual(
            configuration,
            GoogleOAuthClientConfiguration(
                clientID: "environment-id",
                clientSecret: "environment-secret"
            )
        )
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(
            GoogleDriveOAuthContract.codeChallenge(
                for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            ),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizationURLUsesMinimalDriveScopeAndOfflinePKCE() throws {
        let url = GoogleDriveOAuthContract.authorizationURL(
            configuration: GoogleOAuthClientConfiguration(clientID: "client-id"),
            redirectURI: "http://127.0.0.1:54321/oauth2/callback",
            state: "state-value",
            codeChallenge: "challenge-value"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value)
        })
        XCTAssertEqual(values["client_id"], "client-id")
        XCTAssertEqual(values["redirect_uri"], "http://127.0.0.1:54321/oauth2/callback")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["scope"], GoogleDriveOAuthContract.driveScope)
        XCTAssertEqual(values["access_type"], "offline")
        XCTAssertEqual(values["prompt"], "consent")
        XCTAssertEqual(values["code_challenge"], "challenge-value")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["state"], "state-value")
    }

    func testCallbackParsesEncodedValuesAndIgnoresDuplicateNames() throws {
        let callback = try GoogleOAuthCallback.parse(
            requestTarget: "/oauth2/callback?code=first&code=second&state=a%20b"
        )
        XCTAssertEqual(callback.code, "first")
        XCTAssertEqual(callback.state, "a b")
        XCTAssertNil(callback.error)
    }

    func testCallbackRejectsWrongPath() {
        XCTAssertThrowsError(try GoogleOAuthCallback.parse(requestTarget: "/not-oauth")) {
            XCTAssertEqual(
                $0 as? GoogleDriveConnectionError,
                .invalidAuthorizationCallback
            )
        }
        XCTAssertThrowsError(
            try GoogleOAuthCallback.parse(requestTarget: "/oauth2/callback-impersonator?code=x")
        ) {
            XCTAssertEqual(
                $0 as? GoogleDriveConnectionError,
                .invalidAuthorizationCallback
            )
        }
    }

    func testLoopbackListenerBindsIPv4Localhost() throws {
        let listener = try GoogleOAuthLoopbackServer()
        defer { listener.close() }
        XCTAssertEqual(
            listener.redirectURI,
            "http://127.0.0.1:\(listener.port)/oauth2/callback"
        )
        XCTAssertGreaterThan(listener.port, 0)
    }

    func testLoopbackListenerCompletesRealHTTPCallback() async throws {
        let listener = try GoogleOAuthLoopbackServer()
        let waiting = Task { try await listener.waitForCallback(timeout: 5) }
        let callbackURL = try XCTUnwrap(
            URL(string: listener.redirectURI + "?code=auth-code&state=csrf-state")
        )
        let (body, response) = try await URLSession.shared.data(from: callbackURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Authorization received"))
        let callback = try await waiting.value
        XCTAssertEqual(callback.code, "auth-code")
        XCTAssertEqual(callback.state, "csrf-state")
    }

    func testCancelledCallbackWaitStopsPromptly() async throws {
        let listener = try GoogleOAuthLoopbackServer()
        let waiting = Task { try await listener.waitForCallback(timeout: 5) }
        try await Task.sleep(for: .milliseconds(20))
        let started = ProcessInfo.processInfo.systemUptime
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancellation must not produce authorization")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testAcceptedClientWithoutRequestHonorsDeadline() async throws {
        let listener = try GoogleOAuthLoopbackServer()
        let client = try connectClient(port: listener.port)
        defer { Darwin.close(client) }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await listener.waitForCallback(timeout: 0.15)
            XCTFail("Silent client must time out")
        } catch {
            XCTAssertEqual(error as? GoogleDriveConnectionError, .authorizationTimedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

    func testAcceptedSilentClientCanBeCancelled() async throws {
        let listener = try GoogleOAuthLoopbackServer()
        let client = try connectClient(port: listener.port)
        defer { Darwin.close(client) }
        let waiting = Task { try await listener.waitForCallback(timeout: 5) }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Silent client must not hold cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFragmentedRequestLineIsReadCompletely() async throws {
        let listener = try GoogleOAuthLoopbackServer()
        let client = try connectClient(port: listener.port)
        defer { Darwin.close(client) }
        let waiting = Task { try await listener.waitForCallback(timeout: 2) }
        let prefix = Array("GET /oauth2/callback?code=fragmented&".utf8)
        XCTAssertEqual(prefix.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }, prefix.count)
        try await Task.sleep(for: .milliseconds(20))
        let suffix = Array("state=complete HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        XCTAssertEqual(suffix.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }, suffix.count)
        let callback = try await waiting.value
        XCTAssertEqual(callback.code, "fragmented")
        XCTAssertEqual(callback.state, "complete")
    }

    private func connectClient(port: UInt16) throws -> Int32 {
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            Darwin.close(client)
            throw GoogleDriveConnectionError.unableToCreateLoopbackListener(errno)
        }
        return client
    }

    @MainActor
    func testConnectionRefreshFolderProvisionAndDisconnectEndToEnd() async throws {
        MockGoogleURLProtocol.lock.withLock {
            MockGoogleURLProtocol.permissionID = "permission-1"
            MockGoogleURLProtocol.folderExists = false
            MockGoogleURLProtocol.tokenRequests = 0
            MockGoogleURLProtocol.requests = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoogleURLProtocol.self]
        let store = MemoryCredentialStore()
        let manager = GoogleDriveConnectionManager(
            bundledConfiguration: GoogleOAuthClientConfiguration(clientID: "desktop-client"),
            session: URLSession(configuration: configuration),
            credentialStore: store
        )

        let identity = try await manager.connect { authorizationURL in
            let query = URLComponents(
                url: authorizationURL,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            let redirect = try XCTUnwrap(
                query.first(where: { $0.name == "redirect_uri" })?.value
            )
            let state = try XCTUnwrap(query.first(where: { $0.name == "state" })?.value)
            let callback = try XCTUnwrap(
                URL(string: redirect + "?code=test-code&state=" + state)
            )
            Task { _ = try await URLSession.shared.data(from: callback) }
        }
        XCTAssertEqual(identity.emailAddress, "test@example.com")
        XCTAssertEqual(identity.rootFolderID, "folder-1")
        XCTAssertEqual(identity.storageUsage, 42)
        let connectedStatus = try await manager.configurationStatus()
        XCTAssertTrue(connectedStatus.hasSavedAuthorization)
        try await manager.validateSavedAuthorizationToken()

        let restored = try await manager.restore()
        XCTAssertEqual(restored, identity)
        try await manager.disconnect()
        let disconnectedStatus = try await manager.configurationStatus()
        let disconnectedIdentity = try await manager.savedConnectionIdentity()
        XCTAssertFalse(disconnectedStatus.hasSavedAuthorization)
        XCTAssertNil(disconnectedIdentity)

        let requests = MockGoogleURLProtocol.lock.withLock {
            MockGoogleURLProtocol.requests
        }
        XCTAssertTrue(requests.contains { $0.url?.path == "/drive/v3/about" })
        XCTAssertTrue(requests.contains {
            $0.url?.path == "/drive/v3/files" && $0.httpMethod == "POST"
        })
        XCTAssertTrue(requests.filter { $0.url?.path == "/token" }.count >= 2)
        XCTAssertTrue(requests.filter { $0.url?.host == "www.googleapis.com" }.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        })
    }

    @MainActor
    func testAuthorizationLeavesActiveCredentialsAndTokenUnchangedUntilCommit() async throws {
        MockGoogleURLProtocol.lock.withLock {
            MockGoogleURLProtocol.permissionID = "permission-1"
            MockGoogleURLProtocol.folderExists = false
            MockGoogleURLProtocol.tokenRequests = 0
            MockGoogleURLProtocol.requests = []
        }
        defer { MockGoogleURLProtocol.lock.withLock { MockGoogleURLProtocol.permissionID = "permission-1" } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoogleURLProtocol.self]
        let store = MemoryCredentialStore()
        let manager = GoogleDriveConnectionManager(
            bundledConfiguration: GoogleOAuthClientConfiguration(clientID: "desktop-client"),
            session: URLSession(configuration: configuration), credentialStore: store
        )
        let browser: GoogleDriveConnectionManager.BrowserOpener = { authorizationURL in
            let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
            let state = try XCTUnwrap(query.first { $0.name == "state" }?.value)
            let callback = try XCTUnwrap(URL(string: redirect + "?code=test-code&state=" + state))
            Task { _ = try await URLSession.shared.data(from: callback) }
        }
        let first = try await manager.authorize(openBrowser: browser)
        XCTAssertTrue(store.snapshot.isEmpty)
        XCTAssertEqual(first.credentialUpdates.count, 2)
        let beforeCommit = try await manager.configurationStatus()
        XCTAssertFalse(beforeCommit.hasSavedAuthorization)
        for (account, data) in first.credentialUpdates { try store.set(data, account: account) }
        await manager.acceptPersistedAuthorization(first)
        let firstToken = try await manager.validAccessToken()
        XCTAssertEqual(firstToken, "access-one")
        let saved = store.snapshot

        let second = try await manager.authorize(openBrowser: browser)
        XCTAssertEqual(store.snapshot, saved)
        let tokenWhilePending = try await manager.validAccessToken()
        XCTAssertEqual(tokenWhilePending, "access-one")
        XCTAssertEqual(second.identity, first.identity)
        for (account, data) in second.credentialUpdates { try store.set(data, account: account) }
        let persisted = store.snapshot
        await manager.acceptPersistedAuthorization(second)
        XCTAssertEqual(store.snapshot, persisted, "Accepting a persisted authorization only changes the bearer cache")
        let secondToken = try await manager.validAccessToken()
        XCTAssertEqual(secondToken, "access-two")

        MockGoogleURLProtocol.lock.withLock { MockGoogleURLProtocol.permissionID = "different-account" }
        do {
            _ = try await manager.authorize(openBrowser: browser)
            XCTFail("An authorization for another account must not reuse the previous refresh token")
        } catch {
            XCTAssertEqual(error as? GoogleDriveConnectionError, .missingRefreshToken)
        }
        XCTAssertEqual(store.snapshot, persisted)
        let tokenAfterFailure = try await manager.validAccessToken()
        XCTAssertEqual(tokenAfterFailure, "access-two")
    }

}
