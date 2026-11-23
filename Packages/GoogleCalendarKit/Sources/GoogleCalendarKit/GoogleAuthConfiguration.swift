import Foundation

/// Everything the package needs to know about the Google OAuth client.
///
/// Create a **Desktop app** OAuth client in Google Cloud Console (see
/// `docs/google-oauth-setup.md`) and pass its values in here. Never hard-code real
/// credentials in source; the app reads them from a git-ignored xcconfig via Info.plist
/// (see ``init(bundle:)``).
///
/// The redirect is a loopback address (`http://127.0.0.1:<port><redirectPath>`), which is
/// what Google currently supports for macOS desktop apps. Desktop clients accept any
/// loopback port, so by default a random free port is used.
public struct GoogleAuthConfiguration: Sendable, Hashable {
    /// Read-only access to events on all of the user's calendars.
    public static let eventsReadOnlyScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    /// Read-only access to the list of calendars the user is subscribed to.
    public static let calendarListReadOnlyScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    /// The scopes the package requests by default. Both are required.
    public static let defaultScopes = [eventsReadOnlyScope, calendarListReadOnlyScope]

    /// Info.plist key the app sets to `$(GOOGLE_CLIENT_ID)`.
    public static let clientIDInfoPlistKey = "GoogleClientID"
    /// Info.plist key the app sets to `$(GOOGLE_CLIENT_SECRET)`.
    public static let clientSecretInfoPlistKey = "GoogleClientSecret"

    /// The OAuth client ID, e.g. `1234-abc.apps.googleusercontent.com`.
    public var clientID: String
    /// The Desktop app client secret. Google treats it as non-confidential for desktop
    /// apps but its token endpoint still expects it for this client type.
    public var clientSecret: String?
    /// Scopes to request. Keep these read-only.
    public var scopes: [String]
    /// Loopback host for the redirect URI. `127.0.0.1` is what Google recommends.
    public var redirectHost: String
    /// Path component of the redirect URI.
    public var redirectPath: String
    /// Fixed loopback port, or `nil` to let the system pick a free one (recommended).
    public var redirectPort: UInt16?
    /// Keychain service name the tokens are stored under.
    public var keychainService: String
    /// Optional `login_hint` (an email address) to preselect the account.
    public var loginHint: String?

    public init(
        clientID: String,
        clientSecret: String? = nil,
        scopes: [String] = GoogleAuthConfiguration.defaultScopes,
        redirectHost: String = "127.0.0.1",
        redirectPath: String = "/oauth2redirect",
        redirectPort: UInt16? = nil,
        keychainService: String = "GoogleCalendarKit",
        loginHint: String? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.redirectHost = redirectHost
        self.redirectPath = redirectPath.hasPrefix("/") ? redirectPath : "/" + redirectPath
        self.redirectPort = redirectPort
        self.keychainService = keychainService
        self.loginHint = loginHint
    }

    /// Reads ``clientIDInfoPlistKey`` and ``clientSecretInfoPlistKey`` from a bundle's
    /// Info.plist. Returns `nil` when the client ID is missing, empty, or an unexpanded
    /// build setting such as `$(GOOGLE_CLIENT_ID)`.
    public init?(bundle: Bundle = .main, keychainService: String = "GoogleCalendarKit") {
        guard let clientID = Self.resolvedValue(bundle.object(forInfoDictionaryKey: Self.clientIDInfoPlistKey)) else {
            return nil
        }
        self.init(
            clientID: clientID,
            clientSecret: Self.resolvedValue(bundle.object(forInfoDictionaryKey: Self.clientSecretInfoPlistKey)),
            keychainService: keychainService
        )
    }

    static func resolvedValue(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, !string.hasPrefix("$(") else { return nil }
        return string
    }

    /// The redirect URI for a listener bound to `port`.
    func redirectURI(port: UInt16) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = redirectHost
        components.port = Int(port)
        components.path = redirectPath
        return components.url!
    }
}

/// Google's OAuth 2.0 endpoints.
enum GoogleEndpoints {
    static let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let token = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocation = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let calendarAPI = URL(string: "https://www.googleapis.com/calendar/v3")!
}
