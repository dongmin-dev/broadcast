import Foundation
import Observation
import os

/// Supplies OAuth access tokens to ``GoogleCalendarClient``.
public protocol AccessTokenProvider: Sendable {
    /// Returns a valid access token, refreshing it first when it is about to expire or
    /// when `forceRefresh` is `true` (used after the API answered 401).
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Google sign-in, token storage and refresh.
///
/// Observable on the main actor, so a settings view can read ``isSignedIn`` and
/// ``accountEmail`` directly. Tokens live in the Keychain (by default) and access tokens
/// are refreshed automatically; concurrent refreshes are coalesced into one request.
@MainActor
@Observable
public final class GoogleAuth: AccessTokenProvider {
    /// Whether a refresh token is stored.
    public private(set) var isSignedIn: Bool
    /// Email address of the signed-in account (the primary calendar's ID), for display.
    public private(set) var accountEmail: String?
    /// Whether ``signIn()`` is waiting for the browser.
    public private(set) var isSigningIn = false

    public let configuration: GoogleAuthConfiguration

    @ObservationIgnored private var credential: StoredCredential?
    @ObservationIgnored private var refreshTask: Task<StoredCredential, any Error>?
    @ObservationIgnored private var signInTask: Task<Void, any Error>?
    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let endpoint: OAuthEndpoint
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let userAgent: any AuthorizationUserAgent
    @ObservationIgnored private let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: "GoogleCalendarKit", category: "GoogleAuth")

    /// - Parameters:
    ///   - configuration: OAuth client values.
    ///   - store: Where tokens are kept. Defaults to the Keychain under `configuration.keychainService`.
    ///   - transport: HTTP transport. Defaults to `URLSession.shared`.
    ///   - userAgent: Presents the consent page. Defaults to the browser + loopback listener.
    ///   - now: Clock, for tests.
    public init(
        configuration: GoogleAuthConfiguration,
        store: (any CredentialStore)? = nil,
        transport: any HTTPTransport = URLSessionTransport(),
        userAgent: any AuthorizationUserAgent = LoopbackAuthorizationUserAgent(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store ?? KeychainCredentialStore(service: configuration.keychainService)
        self.transport = transport
        self.endpoint = OAuthEndpoint(configuration: configuration, transport: transport)
        self.userAgent = userAgent
        self.now = now
        do {
            credential = try self.store.loadCredential()
        } catch {
            Self.logger.error("Could not load stored Google credential: \(String(describing: error), privacy: .public)")
            credential = nil
        }
        isSignedIn = credential != nil
        accountEmail = credential?.email
    }

    // MARK: Sign in / out

    /// Opens Google's consent page in the browser, waits for the redirect, exchanges the
    /// code for tokens and stores them. Cancelling the calling task cancels the sign-in.
    public func signIn() async throws {
        guard signInTask == nil else { throw GoogleCalendarError.signInInProgress }
        let task = Task { try await performSignIn() }
        signInTask = task
        isSigningIn = true
        defer {
            signInTask = nil
            isSigningIn = false
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSignIn() async throws {
        let configuration = self.configuration
        let pkce = PKCE.generate()
        let state = makeOAuthState()
        let redirect: URL
        do {
            redirect = try await userAgent.authorize(configuration: configuration) { redirectURI in
                AuthorizationRequest(configuration: configuration, redirectURI: redirectURI, pkce: pkce, state: state).url
            }
        } catch is CancellationError {
            throw GoogleCalendarError.signInCancelled
        }
        let redirectURI = Self.redirectURI(from: redirect)
        let request = AuthorizationRequest(configuration: configuration, redirectURI: redirectURI, pkce: pkce, state: state)
        let code = try request.authorizationCode(from: redirect)
        let tokens = try await endpoint.exchange(code: code, request: request)
        let issuedAt = now()

        guard let refreshToken = tokens.refreshToken else {
            throw GoogleCalendarError.invalidResponse("Google did not return a refresh token")
        }
        let granted = tokens.scopes ?? configuration.scopes
        let missing = configuration.scopes.filter { !granted.contains($0) }
        guard missing.isEmpty else {
            try? await endpoint.revoke(token: refreshToken)
            throw GoogleCalendarError.missingScopes(missing)
        }

        var newCredential = StoredCredential(
            accessToken: tokens.accessToken,
            accessTokenExpiry: issuedAt.addingTimeInterval(tokens.expiresIn),
            refreshToken: refreshToken,
            grantedScopes: granted,
            email: nil
        )
        newCredential.email = try? await fetchAccountEmail(accessToken: tokens.accessToken)
        try Task.checkCancellation()

        // Replace any previous account. Revoke its refresh token if it differs.
        if let old = credential, old.refreshToken != refreshToken {
            try? await endpoint.revoke(token: old.refreshToken)
        }
        try store.saveCredential(newCredential)
        apply(newCredential)
    }

    /// Revokes the refresh token at Google (best effort; failures such as being offline
    /// are ignored) and deletes the stored tokens.
    public func signOut() async throws {
        signInTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        let old = credential
        try store.removeCredential()
        apply(nil)
        if let old {
            do {
                try await endpoint.revoke(token: old.refreshToken)
            } catch {
                Self.logger.notice("Token revocation failed (ignored): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Tokens

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credential else { throw GoogleCalendarError.notSignedIn }
        if !forceRefresh, credential.isAccessTokenValid(at: now()) {
            return credential.accessToken
        }
        return try await refreshedCredential().accessToken
    }

    /// Refreshes the access token, sharing one in-flight request between callers.
    private func refreshedCredential() async throws -> StoredCredential {
        if let refreshTask { return try await refreshTask.value }
        guard let current = credential else { throw GoogleCalendarError.notSignedIn }
        let endpoint = self.endpoint
        let now = self.now
        let task = Task<StoredCredential, any Error> {
            let tokens = try await endpoint.refresh(refreshToken: current.refreshToken)
            var updated = current
            updated.accessToken = tokens.accessToken
            updated.accessTokenExpiry = now().addingTimeInterval(tokens.expiresIn)
            if let rotated = tokens.refreshToken { updated.refreshToken = rotated }
            if let scopes = tokens.scopes { updated.grantedScopes = scopes }
            return updated
        }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        do {
            var updated = try await task.value
            if updated.email == nil {
                updated.email = try? await fetchAccountEmail(accessToken: updated.accessToken)
            }
            // Ignore the result if the user signed out or switched accounts meanwhile.
            guard credential?.refreshToken == current.refreshToken else { throw GoogleCalendarError.notSignedIn }
            commitRefresh(updated)
            return updated
        } catch GoogleCalendarError.reauthenticationRequired {
            Self.logger.notice("Refresh token rejected; clearing the session")
            if credential?.refreshToken == current.refreshToken {
                try? store.removeCredential()
                apply(nil)
            }
            throw GoogleCalendarError.reauthenticationRequired
        }
    }

    private func commitRefresh(_ updated: StoredCredential) {
        do {
            try store.saveCredential(updated)
        } catch {
            // The new access token is still usable in memory.
            Self.logger.error("Could not persist refreshed token: \(String(describing: error), privacy: .public)")
        }
        apply(updated)
    }

    private func apply(_ credential: StoredCredential?) {
        self.credential = credential
        if isSignedIn != (credential != nil) { isSignedIn = credential != nil }
        if accountEmail != credential?.email { accountEmail = credential?.email }
    }

    /// The primary calendar's ID is the account's email address; this avoids requesting
    /// the extra `email` scope.
    private func fetchAccountEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: GoogleEndpoints.calendarAPI.appending(path: "users/me/calendarList/primary"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GoogleCalendarError.http(status: response.statusCode, message: nil)
        }
        struct Primary: Decodable { let id: String }
        return try JSONDecoder().decode(Primary.self, from: data).id
    }

    private static func redirectURI(from redirect: URL) -> URL {
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.fragment = nil
        return components.url!
    }
}
