import Foundation
import Synchronization
@testable import GoogleCalendarKit

/// A transport that answers from a handler and records every request.
final class StubTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, [String: String], Data)

    private let handler: Handler
    private let recorded = Mutex<[URLRequest]>([])

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func requests(to host: String, path: String? = nil) -> [URLRequest] {
        requests.filter { $0.url?.host == host && (path == nil || $0.url?.path == path) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let (status, headers, body) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

/// Simulates the browser: reads `state` from the authorization URL and redirects back.
final class StubUserAgent: AuthorizationUserAgent {
    let redirectURI = URL(string: "http://127.0.0.1:49152/oauth2redirect")!
    let code: String?
    let error: String?
    let overrideState: String?
    let capturedURL = Mutex<URL?>(nil)

    init(code: String? = "auth-code-123", error: String? = nil, overrideState: String? = nil) {
        self.code = code
        self.error = error
        self.overrideState = overrideState
    }

    func authorize(configuration: GoogleAuthConfiguration, makeAuthorizationURL: @Sendable (URL) -> URL) async throws -> URL {
        let url = makeAuthorizationURL(redirectURI)
        capturedURL.withLock { $0 = url }
        let state = overrideState ?? queryItems(url)["state"] ?? ""
        var pairs = [("state", state)]
        if let code { pairs.append(("code", code)) }
        if let error { pairs.append(("error", error)) }
        return URL(string: redirectURI.absoluteString + "?" + FormEncoding.encode(pairs))!
    }
}

final class CancellingUserAgent: AuthorizationUserAgent {
    func authorize(configuration: GoogleAuthConfiguration, makeAuthorizationURL: @Sendable (URL) -> URL) async throws -> URL {
        throw CancellationError()
    }
}

func queryItems(_ url: URL) -> [String: String] {
    FormEncoding.decode(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
}

func formBody(_ request: URLRequest) -> [String: String] {
    FormEncoding.decode(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
}

func json(_ string: String) -> Data { Data(string.utf8) }

/// A clock tests can move.
final class TestClock: Sendable {
    private let current: Mutex<Date>
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = Mutex(date) }
    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

let testConfiguration = GoogleAuthConfiguration(clientID: "test-client.apps.googleusercontent.com", clientSecret: "test-secret")

/// Fixed token provider for client tests.
final class StubTokens: AccessTokenProvider {
    private let state = Mutex<(token: Int, forced: Int)>((1, 0))
    var forcedRefreshes: Int { state.withLock { $0.forced } }

    func accessToken(forceRefresh: Bool) async throws -> String {
        state.withLock { state in
            if forceRefresh { state.token += 1; state.forced += 1 }
            return "token-\(state.token)"
        }
    }
}

/// Thread-safe list of values recorded from `@Sendable` closures.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
    /// Appends and returns the new count.
    func record(_ value: Value) -> Int { storage.withLock { $0.append(value); return $0.count } }
}
