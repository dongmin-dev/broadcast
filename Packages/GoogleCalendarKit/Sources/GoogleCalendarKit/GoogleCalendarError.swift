import Foundation

/// Errors thrown by ``GoogleAuth`` and ``GoogleCalendarClient``.
public enum GoogleCalendarError: Error, Sendable, Equatable {
    /// No account is signed in.
    case notSignedIn
    /// ``GoogleAuth/signIn()`` was called while another sign-in was in progress.
    case signInInProgress
    /// The user closed or cancelled the sign-in, or it timed out.
    case signInCancelled
    /// Google redirected back with an error, e.g. `access_denied` when the user declined.
    case authorizationFailed(error: String, description: String?)
    /// The redirect's `state` did not match the request (possible CSRF); the code was ignored.
    case stateMismatch
    /// The redirect did not contain an authorization code.
    case missingAuthorizationCode
    /// The user granted fewer scopes than required (granular consent). Contains the missing scopes.
    case missingScopes([String])
    /// The refresh token was revoked or expired. The local session was cleared; sign in again.
    case reauthenticationRequired
    /// The token endpoint returned an OAuth error other than `invalid_grant`.
    case oauth(error: String, description: String?)
    /// The API still answered 401 after refreshing the access token once.
    case unauthorized
    /// The API answered 403 for a reason other than rate limiting (e.g. insufficient permissions).
    case forbidden(reason: String?, message: String?)
    /// The requested calendar does not exist or is not visible to the user.
    case notFound(message: String?)
    /// Rate limited (429 or 403 rateLimitExceeded) after the retry policy was exhausted.
    case rateLimited(retryAfter: TimeInterval?)
    /// No network connection, or the host could not be reached.
    case offline
    /// The loopback redirect listener could not be started.
    case redirectListenerFailed(String)
    /// Could not open the browser for sign-in.
    case browserUnavailable
    /// Any other unexpected HTTP status.
    case http(status: Int, message: String?)
    /// A response could not be decoded.
    case invalidResponse(String)
    /// A Keychain operation failed with this `OSStatus`.
    case keychain(OSStatus)
    /// A transport error that is neither offline nor cancellation.
    case network(String)
}

extension GoogleCalendarError {
    /// Maps transport errors into ``GoogleCalendarError``.
    static func from(transportError error: any Error) -> any Error {
        if let error = error as? GoogleCalendarError { return error }
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return GoogleCalendarError.offline
            default:
                return GoogleCalendarError.network(urlError.localizedDescription)
            }
        }
        return GoogleCalendarError.network(String(describing: error))
    }
}
