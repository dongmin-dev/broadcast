import Foundation

/// One authorization attempt: PKCE pair, CSRF state and redirect URI.
struct AuthorizationRequest: Sendable {
    let configuration: GoogleAuthConfiguration
    let redirectURI: URL
    let pkce: PKCE
    let state: String

    init(configuration: GoogleAuthConfiguration, redirectURI: URL, pkce: PKCE = .generate(), state: String = makeOAuthState()) {
        self.configuration = configuration
        self.redirectURI = redirectURI
        self.pkce = pkce
        self.state = state
    }

    /// The URL to open in the user's browser.
    var url: URL {
        var items: [(String, String)] = [
            ("client_id", configuration.clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("response_type", "code"),
            ("scope", configuration.scopes.joined(separator: " ")),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
            ("state", state),
            // Ask for a refresh token, and re-show consent so one is issued even on re-sign-in.
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        if let hint = configuration.loginHint { items.append(("login_hint", hint)) }
        var components = URLComponents(url: GoogleEndpoints.authorization, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(items)
        return components.url!
    }

    /// Validates the redirect URL and returns the authorization code.
    func authorizationCode(from redirect: URL) throws -> String {
        let query = FormEncoding.decode(URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        guard query["state"] == state else { throw GoogleCalendarError.stateMismatch }
        if let error = query["error"] {
            throw GoogleCalendarError.authorizationFailed(error: error, description: query["error_description"])
        }
        guard let code = query["code"], !code.isEmpty else { throw GoogleCalendarError.missingAuthorizationCode }
        return code
    }
}

/// Response of Google's token endpoint.
struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }

    var scopes: [String]? {
        scope.map { $0.split(separator: " ").map(String.init) }
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// Talks to Google's token and revocation endpoints.
struct OAuthEndpoint: Sendable {
    let configuration: GoogleAuthConfiguration
    let transport: any HTTPTransport

    private var clientPairs: [(String, String)] {
        var pairs = [("client_id", configuration.clientID)]
        if let secret = configuration.clientSecret { pairs.append(("client_secret", secret)) }
        return pairs
    }

    func exchange(code: String, request: AuthorizationRequest) async throws -> TokenResponse {
        try await tokenRequest(clientPairs + [
            ("code", code),
            ("code_verifier", request.pkce.verifier),
            ("redirect_uri", request.redirectURI.absoluteString),
            ("grant_type", "authorization_code"),
        ])
    }

    func refresh(refreshToken: String) async throws -> TokenResponse {
        try await tokenRequest(clientPairs + [
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
    }

    /// Revokes a token. Revoking the refresh token also invalidates its access tokens.
    func revoke(token: String) async throws {
        let request = FormEncoding.formRequest(url: GoogleEndpoints.revocation, [("token", token)])
        let (data, response) = try await transport.send(request)
        // 400 invalid_token means it is already revoked or expired, which is fine.
        guard (200..<300).contains(response.statusCode) || response.statusCode == 400 else {
            throw GoogleCalendarError.http(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
    }

    private func tokenRequest(_ pairs: [(String, String)]) async throws -> TokenResponse {
        let request = FormEncoding.formRequest(url: GoogleEndpoints.token, pairs)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                if error.error == "invalid_grant" { throw GoogleCalendarError.reauthenticationRequired }
                throw GoogleCalendarError.oauth(error: error.error, description: error.errorDescription)
            }
            if response.statusCode == 429 {
                throw GoogleCalendarError.rateLimited(retryAfter: response.retryAfter)
            }
            throw GoogleCalendarError.http(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse("Token response: \(error)")
        }
    }
}

extension HTTPURLResponse {
    /// `Retry-After` in seconds, if present and numeric.
    var retryAfter: TimeInterval? {
        value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }
}
