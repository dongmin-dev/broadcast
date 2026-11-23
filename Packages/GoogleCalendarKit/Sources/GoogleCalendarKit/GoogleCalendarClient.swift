import Foundation
import os

/// How the client retries rate-limited and transient server errors.
public struct RetryPolicy: Sendable, Hashable {
    /// Retries after the first attempt.
    public var maxRetries: Int
    /// Delay before the first retry; doubles each time.
    public var baseDelay: Duration
    /// Longest delay the client will wait. A larger `Retry-After` is not waited for.
    public var maxDelay: Duration

    public init(maxRetries: Int = 3, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(16)) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxRetries: 0)
}

/// Reads calendars and events through the Google Calendar API v3.
public struct GoogleCalendarClient: Sendable {
    private let tokens: any AccessTokenProvider
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let allDayTimeZone: TimeZone
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pageSize: Int
    private static let logger = Logger(subsystem: "GoogleCalendarKit", category: "GoogleCalendarClient")
    /// Safety stop for runaway paging.
    static let maxPages = 100

    /// - Parameters:
    ///   - auth: Usually the app's ``GoogleAuth``.
    ///   - transport: HTTP transport. Defaults to `URLSession.shared`.
    ///   - retryPolicy: Backoff for 429 / rate-limit 403 / 5xx responses.
    ///   - allDayTimeZone: Time zone in which all-day dates start at midnight. Defaults to the current one.
    public init(
        auth: any AccessTokenProvider,
        transport: any HTTPTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default,
        allDayTimeZone: TimeZone = .current
    ) {
        self.init(auth: auth, transport: transport, retryPolicy: retryPolicy, allDayTimeZone: allDayTimeZone,
                  pageSize: 250, sleep: { try await Task.sleep(for: $0) })
    }

    init(
        auth: any AccessTokenProvider,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy,
        allDayTimeZone: TimeZone,
        pageSize: Int,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.tokens = auth
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.allDayTimeZone = allDayTimeZone
        self.pageSize = pageSize
        self.sleep = sleep
    }

    // MARK: Public API

    /// All calendars in the user's calendar list.
    public func calendars() async throws -> [GoogleCalendar] {
        var result: [GoogleCalendar] = []
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var query = [("maxResults", "250")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: CalendarListPage = try await get(path: ["users", "me", "calendarList"], query: query)
            result += (page.items ?? []).filter { $0.deleted != true }.map(GoogleCalendar.init)
            pageToken = page.nextPageToken
            if pageToken == nil { break }
        }
        return result
    }

    /// Events overlapping `start..<end` on the given calendars, with recurring events
    /// expanded into instances, sorted by start time. Cancelled events are omitted unless
    /// `includeCancelled` is `true` (they then come back with `isCancelled == true` when
    /// Google still returns their times).
    public func events(
        calendarIDs: some Sequence<String>,
        from start: Date,
        to end: Date,
        includeCancelled: Bool = false
    ) async throws -> [GoogleCalendarEvent] {
        let ids = Array(Set(calendarIDs)).sorted()
        let perCalendar = try await withThrowingTaskGroup(of: [GoogleCalendarEvent].self) { group in
            for id in ids {
                group.addTask {
                    try await events(calendarID: id, from: start, to: end, includeCancelled: includeCancelled)
                }
            }
            var all: [GoogleCalendarEvent] = []
            for try await events in group { all += events }
            return all
        }
        return perCalendar.sorted {
            ($0.start, $0.end, $0.calendarID, $0.id) < ($1.start, $1.end, $1.calendarID, $1.id)
        }
    }

    func events(calendarID: String, from start: Date, to end: Date, includeCancelled: Bool) async throws -> [GoogleCalendarEvent] {
        var result: [GoogleCalendarEvent] = []
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var query = [
                ("singleEvents", "true"),
                ("orderBy", "startTime"),
                ("timeMin", RFC3339.string(from: start)),
                ("timeMax", RFC3339.string(from: end)),
                ("maxResults", String(pageSize)),
            ]
            if includeCancelled { query.append(("showDeleted", "true")) }
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: EventsPage = try await get(path: ["calendars", calendarID, "events"], query: query)
            result += (page.items ?? []).compactMap {
                EventMapping.event(from: $0, calendarID: calendarID, allDayTimeZone: allDayTimeZone)
            }
            pageToken = page.nextPageToken
            if pageToken == nil { break }
        }
        return includeCancelled ? result : result.filter { !$0.isCancelled }
    }

    // MARK: Requests

    /// Builds a URL under the Calendar API base, percent-encoding each path segment
    /// (calendar IDs contain `@` and `#`).
    static func url(path: [String], query: [(String, String)]) -> URL {
        let base = GoogleEndpoints.calendarAPI.absoluteString
        let encodedPath = path.map(FormEncoding.escape).joined(separator: "/")
        let queryString = query.isEmpty ? "" : "?" + FormEncoding.encode(query)
        return URL(string: "\(base)/\(encodedPath)\(queryString)")!
    }

    private func get<T: Decodable>(path: [String], query: [(String, String)]) async throws -> T {
        let url = Self.url(path: path, query: query)
        let data = try await authorizedData(for: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse("\(T.self): \(error)")
        }
    }

    /// GET with bearer token: refresh-and-retry once on 401; back off on rate limits and 5xx.
    private func authorizedData(for url: URL) async throws -> Data {
        var refreshedAfter401 = false
        var retries = 0
        while true {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: false)
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if (200..<300).contains(status) { return data }

            let apiError = APIErrorBody.decode(data)
            let isRateLimit = status == 429 || (status == 403 && apiError.isRateLimit)
            if isRateLimit || [500, 502, 503, 504].contains(status) {
                let retryAfter = response.retryAfter
                if retries < retryPolicy.maxRetries, let delay = delay(forRetry: retries, retryAfter: retryAfter) {
                    retries += 1
                    Self.logger.info("HTTP \(status) from Calendar API; retry \(retries) after \(delay)")
                    try await sleep(delay)
                    continue
                }
                if isRateLimit { throw GoogleCalendarError.rateLimited(retryAfter: retryAfter) }
                throw GoogleCalendarError.http(status: status, message: apiError.message)
            }
            switch status {
            case 401:
                if refreshedAfter401 { throw GoogleCalendarError.unauthorized }
                refreshedAfter401 = true
                _ = try await tokens.accessToken(forceRefresh: true)
                continue
            case 403:
                throw GoogleCalendarError.forbidden(reason: apiError.reason, message: apiError.message)
            case 404:
                throw GoogleCalendarError.notFound(message: apiError.message)
            default:
                throw GoogleCalendarError.http(status: status, message: apiError.message)
            }
        }
    }

    private func delay(forRetry attempt: Int, retryAfter: TimeInterval?) -> Duration? {
        if let retryAfter {
            let requested = Duration.milliseconds(Int64(retryAfter * 1000))
            return requested <= retryPolicy.maxDelay ? requested : nil
        }
        let exponential = retryPolicy.baseDelay * (1 << min(attempt, 16))
        return min(exponential, retryPolicy.maxDelay)
    }
}

/// `{"error": {"code": 403, "message": "...", "errors": [{"reason": "rateLimitExceeded"}]}}`
struct APIErrorBody: Decodable {
    struct Inner: Decodable {
        struct Item: Decodable { let reason: String? }
        let message: String?
        let errors: [Item]?
        let status: String?
    }

    let error: Inner?

    static func decode(_ data: Data) -> APIErrorBody {
        (try? JSONDecoder().decode(APIErrorBody.self, from: data)) ?? APIErrorBody(error: nil)
    }

    var reason: String? { error?.errors?.first?.reason }
    var message: String? { error?.message }

    var isRateLimit: Bool {
        guard let reason else { return error?.status == "RESOURCE_EXHAUSTED" }
        return ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded"].contains(reason)
    }
}
