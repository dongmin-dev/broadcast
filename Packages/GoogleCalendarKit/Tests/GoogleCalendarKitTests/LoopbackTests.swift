import Foundation
import Testing
@testable import GoogleCalendarKit

/// Exercises the real loopback listener on 127.0.0.1 (no external network).
@Suite("Loopback redirect")
struct LoopbackTests {
    /// Plays the browser: follows the authorization URL's redirect_uri back to the listener.
    private static func browser(appending query: String, probeOtherPathFirst: Bool = false) -> LoopbackAuthorizationUserAgent.Opener {
        { authURL in
            guard let redirect = queryItems(authURL)["redirect_uri"] else { return false }
            Task {
                if probeOtherPathFirst {
                    let favicon = URL(string: redirect)!.deletingLastPathComponent().appending(path: "favicon.ico")
                    _ = try? await URLSession.shared.data(from: favicon)
                }
                _ = try? await URLSession.shared.data(from: URL(string: redirect + "?" + query)!)
            }
            return true
        }
    }

    @Test("Receives the redirect on a random loopback port")
    func receivesRedirect() async throws {
        let agent = LoopbackAuthorizationUserAgent(timeout: .seconds(10), open: Self.browser(appending: "state=abc&code=4%2F0xyz", probeOtherPathFirst: true))
        let redirect = try await agent.authorize(configuration: testConfiguration) { redirectURI in
            #expect(redirectURI.host == "127.0.0.1")
            #expect(redirectURI.path == "/oauth2redirect")
            #expect((redirectURI.port ?? 0) > 0)
            return AuthorizationRequest(configuration: testConfiguration, redirectURI: redirectURI, state: "abc").url
        }
        #expect(redirect.path == "/oauth2redirect")
        #expect(queryItems(redirect)["code"] == "4/0xyz")
        #expect(queryItems(redirect)["state"] == "abc")
    }

    @Test("Times out as signInCancelled when the browser never returns")
    func timeout() async throws {
        let agent = LoopbackAuthorizationUserAgent(timeout: .milliseconds(200), open: { _ in true })
        await #expect(throws: GoogleCalendarError.signInCancelled) {
            _ = try await agent.authorize(configuration: testConfiguration) { $0 }
        }
    }

    @Test("Reports when the browser cannot be opened")
    func browserUnavailable() async throws {
        let agent = LoopbackAuthorizationUserAgent(timeout: .seconds(5), open: { _ in false })
        await #expect(throws: GoogleCalendarError.browserUnavailable) {
            _ = try await agent.authorize(configuration: testConfiguration) { $0 }
        }
    }

    @Test("Full sign-in through the loopback listener with a stubbed token endpoint")
    @MainActor
    func endToEnd() async throws {
        let transport = StubTransport { request in
            if request.url?.path == "/token" {
                return (200, [:], json(#"{"access_token":"a","expires_in":3600,"refresh_token":"r","scope":"https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly"}"#))
            }
            return (200, [:], json(#"{"id":"me@example.com"}"#))
        }
        let opener: LoopbackAuthorizationUserAgent.Opener = { authURL in
            let query = queryItems(authURL)
            guard let redirect = query["redirect_uri"], let state = query["state"] else { return false }
            Task { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?state=\(state)&code=c0de")!) }
            return true
        }
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(), transport: transport,
                              userAgent: LoopbackAuthorizationUserAgent(timeout: .seconds(10), open: opener))
        try await auth.signIn()
        #expect(auth.isSignedIn)
        #expect(auth.accountEmail == "me@example.com")
        let form = formBody(try #require(transport.requests.first { $0.url?.path == "/token" }))
        #expect(form["code"] == "c0de")
        #expect(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    }
}
