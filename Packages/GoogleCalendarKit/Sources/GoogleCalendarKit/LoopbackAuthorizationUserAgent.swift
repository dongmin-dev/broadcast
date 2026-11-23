import AppKit
import Foundation
import Network
import os
import Synchronization

/// Presents the Google consent page and captures the redirect.
///
/// Implementations start a redirect receiver, call `makeAuthorizationURL` with its
/// redirect URI, show the resulting URL to the user and return the URL Google
/// redirected back to. Tests substitute a stub.
public protocol AuthorizationUserAgent: Sendable {
    func authorize(
        configuration: GoogleAuthConfiguration,
        makeAuthorizationURL: @Sendable (_ redirectURI: URL) -> URL
    ) async throws -> URL
}

/// Opens the consent page in the user's default browser and receives the redirect on a
/// loopback HTTP listener (`http://127.0.0.1:<port>/…`), as Google recommends for macOS
/// desktop apps. Requires the `com.apple.security.network.server` sandbox entitlement.
public struct LoopbackAuthorizationUserAgent: AuthorizationUserAgent {
    /// Opens a URL in a browser; returns `false` if it could not.
    public typealias Opener = @Sendable (URL) async -> Bool

    public static let defaultOpener: Opener = { url in
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    let timeout: Duration
    let open: Opener

    /// - Parameters:
    ///   - timeout: How long to wait for the user to finish in the browser.
    ///   - open: Opens the consent page. Defaults to `NSWorkspace.shared.open`.
    public init(timeout: Duration = .seconds(300), open: @escaping Opener = LoopbackAuthorizationUserAgent.defaultOpener) {
        self.timeout = timeout
        self.open = open
    }

    public func authorize(
        configuration: GoogleAuthConfiguration,
        makeAuthorizationURL: @Sendable (URL) -> URL
    ) async throws -> URL {
        let server = try LoopbackRedirectServer(host: configuration.redirectHost, port: configuration.redirectPort, path: configuration.redirectPath)
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = try configuration.redirectURI(port: port)
        guard await open(makeAuthorizationURL(redirectURI)) else {
            throw GoogleCalendarError.browserUnavailable
        }
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await server.waitForRedirect() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoogleCalendarError.signInCancelled
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// A tiny one-shot HTTP server bound to a loopback address.
final class LoopbackRedirectServer: Sendable {
    private struct State {
        var portContinuation: CheckedContinuation<UInt16, any Error>?
        var redirectContinuation: CheckedContinuation<URL, any Error>?
        var result: Result<URL, any Error>?
        var port: UInt16?
        var stopped = false
    }

    private static let logger = Logger(subsystem: "GoogleCalendarKit", category: "LoopbackRedirectServer")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "GoogleCalendarKit.LoopbackRedirectServer")
    private let path: String
    private let host: String
    private let state = Mutex(State())

    init(host: String, port: UInt16?, path: String) throws {
        self.path = path
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.host = host
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let nwHost: NWEndpoint.Host = host == "127.0.0.1" ? .ipv4(.loopback) : (host == "::1" ? .ipv6(.loopback) : NWEndpoint.Host(host))
        let nwPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: nwHost, port: nwPort)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleCalendarError.redirectListenerFailed(String(describing: error))
        }
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Register under the same lock stop() uses, so a stop that already happened
                // (cancellation won the race) resolves the wait instead of hanging.
                let alreadyStopped = state.withLock { state in
                    if state.stopped { return true }
                    state.portContinuation = continuation
                    return false
                }
                if alreadyStopped {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                listener.stateUpdateHandler = { [weak self] newState in
                    self?.listenerStateChanged(newState)
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Waits for the first request to the redirect path and returns its full URL.
    func waitForRedirect() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<URL, any Error>? = state.withLock { state in
                    if let result = state.result { return result }
                    if state.stopped { return .failure(CancellationError()) }
                    state.redirectContinuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        let (portContinuation, redirectContinuation) = state.withLock { state in
            state.stopped = true
            defer { state.portContinuation = nil; state.redirectContinuation = nil }
            return (state.portContinuation, state.redirectContinuation)
        }
        listener.cancel()
        portContinuation?.resume(throwing: CancellationError())
        redirectContinuation?.resume(throwing: CancellationError())
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            let continuation = state.withLock { state in
                state.port = port
                defer { state.portContinuation = nil }
                return state.portContinuation
            }
            continuation?.resume(returning: port)
        case .failed(let error):
            Self.logger.error("Loopback listener failed: \(error.localizedDescription, privacy: .public)")
            let continuation = state.withLock { state in
                defer { state.portContinuation = nil }
                return state.portContinuation
            }
            continuation?.resume(throwing: GoogleCalendarError.redirectListenerFailed(error.localizedDescription))
            listener.cancel()
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer[..<headerEnd.lowerBound], on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let requestLine = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let port = state.withLock { $0.port } ?? 0
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)\(parts[1])"),
              url.path == path
        else {
            send(status: "404 Not Found", body: "Not found", on: connection)
            return
        }
        let query = FormEncoding.decode(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        let succeeded = query["code"] != nil && query["error"] == nil
        send(status: "200 OK", body: Self.page(succeeded: succeeded), on: connection)
        let continuation: CheckedContinuation<URL, any Error>? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = .success(url)
            defer { state.redirectContinuation = nil }
            return state.redirectContinuation
        }
        continuation?.resume(returning: url)
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func page(succeeded: Bool) -> String {
        // The app still has to exchange the code and check the granted permissions, so this
        // page must not claim the sign-in succeeded.
        let message = succeeded
            ? "Google has sent the response to the app. Return to the app to see whether sign-in finished. You can close this tab."
            : "Sign-in was not completed. You can close this tab and try again from the app."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Google Calendar sign-in</title>\
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0}</style>\
        </head><body><p>\(message)</p></body></html>
        """
    }
}
