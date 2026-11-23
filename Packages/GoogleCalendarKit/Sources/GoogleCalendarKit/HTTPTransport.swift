import Foundation

/// Sends HTTP requests. Swap in a stub to test without the network.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport, backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse("Not an HTTP response")
        }
        return (data, http)
    }
}

extension HTTPTransport {
    /// Sends a request, mapping transport failures to ``GoogleCalendarError``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await data(for: request)
        } catch {
            throw GoogleCalendarError.from(transportError: error)
        }
    }
}

/// `application/x-www-form-urlencoded` and query encoding with a strict allowed set,
/// so that `+`, `&`, `=`, `/`, `#` and `@` in values are always escaped.
enum FormEncoding {
    static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func decode(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1]))
                : ""
            result[key] = value
        }
        return result
    }

    static func formRequest(url: URL, _ pairs: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(encode(pairs).utf8)
        return request
    }
}
