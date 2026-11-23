import Foundation
import Synchronization
import Testing
@testable import GoogleCalendarKit

private let seoul = TimeZone(identifier: "Asia/Seoul")!

private func makeClient(
    _ transport: StubTransport,
    tokens: StubTokens = StubTokens(),
    retry: RetryPolicy = RetryPolicy(maxRetries: 2, baseDelay: .zero),
    pageSize: Int = 250,
    sleeps: Recorder<Duration>? = nil
) -> GoogleCalendarClient {
    GoogleCalendarClient(auth: tokens, transport: transport, retryPolicy: retry, allDayTimeZone: seoul,
                         pageSize: pageSize, sleep: { duration in sleeps?.append(duration) })
}

private let eventsFixture = json("""
{
  "kind": "calendar#events",
  "timeZone": "Asia/Seoul",
  "items": [
    {
      "id": "timed1",
      "iCalUID": "timed1@google.com",
      "status": "confirmed",
      "htmlLink": "https://www.google.com/calendar/event?eid=dGltZWQx",
      "summary": "Standup",
      "description": "Daily sync",
      "location": "Room 4",
      "start": {"dateTime": "2026-11-24T10:00:00+09:00", "timeZone": "Asia/Seoul"},
      "end": {"dateTime": "2026-11-24T10:15:00+09:00", "timeZone": "Asia/Seoul"},
      "hangoutLink": "https://meet.google.com/abc-defg-hij",
      "conferenceData": {"entryPoints": [
        {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"},
        {"entryPointType": "phone", "uri": "tel:+1-555-0100"}
      ]},
      "attendees": [
        {"email": "boss@example.com", "responseStatus": "accepted", "organizer": true},
        {"email": "me@example.com", "self": true, "responseStatus": "accepted"}
      ]
    },
    {
      "id": "allday1",
      "status": "confirmed",
      "summary": "Offsite",
      "start": {"date": "2026-11-25"},
      "end": {"date": "2026-11-27"}
    },
    {
      "id": "cancelled1",
      "status": "cancelled",
      "summary": "Cancelled sync",
      "start": {"dateTime": "2026-11-24T01:00:00Z"},
      "end": {"dateTime": "2026-11-24T02:00:00Z"}
    },
    {
      "id": "declined1",
      "status": "confirmed",
      "summary": "Optional review",
      "start": {"dateTime": "2026-11-24T14:30:00.000+09:00"},
      "end": {"dateTime": "2026-11-24T15:00:00.000+09:00"},
      "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}]
    },
    {
      "id": "zoom1",
      "status": "tentative",
      "summary": "Vendor call",
      "start": {"dateTime": "2026-11-24T16:00:00+09:00"},
      "end": {"dateTime": "2026-11-24T17:00:00+09:00"},
      "conferenceData": {"entryPoints": [
        {"entryPointType": "more", "uri": "https://example.com/more"},
        {"entryPointType": "video", "uri": "https://zoom.us/j/123456789"}
      ]},
      "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "tentative"}]
    },
    {
      "id": "plain1",
      "status": "confirmed",
      "start": {"dateTime": "2026-11-24T18:00:00+09:00"},
      "end": {"dateTime": "2026-11-24T19:00:00+09:00"},
      "location": "",
      "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "needsAction"}]
    },
    {
      "id": "deleted-no-times",
      "status": "cancelled"
    }
  ]
}
""")

private func decodeFixture() throws -> [String: GoogleCalendarEvent] {
    let page = try JSONDecoder().decode(EventsPage.self, from: eventsFixture)
    let events = (page.items ?? []).compactMap { EventMapping.event(from: $0, calendarID: "primary", allDayTimeZone: seoul) }
    return Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
}

@Suite("Event decoding")
struct EventDecodingTests {
    @Test("Timed event with hangoutLink")
    func timed() throws {
        let event = try #require(try decodeFixture()["timed1"])
        #expect(event.title == "Standup")
        #expect(event.calendarID == "primary")
        #expect(event.iCalUID == "timed1@google.com")
        #expect(event.start == Date(timeIntervalSince1970: 1_795_482_000)) // 2026-11-24T01:00:00Z
        #expect(event.end.timeIntervalSince(event.start) == 15 * 60)
        #expect(!event.isAllDay)
        #expect(!event.isCancelled)
        #expect(event.selfResponseStatus == .accepted)
        #expect(event.conferenceURL == URL(string: "https://meet.google.com/abc-defg-hij"))
        #expect(event.location == "Room 4")
        #expect(event.description == "Daily sync")
        #expect(event.htmlLink == URL(string: "https://www.google.com/calendar/event?eid=dGltZWQx"))
    }

    @Test("All-day event starts at local midnight with an exclusive end")
    func allDay() throws {
        let event = try #require(try decodeFixture()["allday1"])
        #expect(event.isAllDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        #expect(event.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 25)))
        #expect(event.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))
        #expect(event.selfResponseStatus == ResponseStatus.none)
        #expect(event.conferenceURL == nil)
        #expect(event.htmlLink == nil)
    }

    @Test("Cancelled event")
    func cancelled() throws {
        let event = try #require(try decodeFixture()["cancelled1"])
        #expect(event.isCancelled)
        #expect(event.start == Date(timeIntervalSince1970: 1_795_482_000))
    }

    @Test("Declined event with fractional seconds")
    func declined() throws {
        let event = try #require(try decodeFixture()["declined1"])
        #expect(event.selfResponseStatus == .declined)
        #expect(event.start == Date(timeIntervalSince1970: 1_795_482_000 + 4.5 * 3600))
        #expect(event.conferenceURL == nil)
    }

    @Test("Video entry point from conferenceData when there is no hangoutLink")
    func conferenceData() throws {
        let event = try #require(try decodeFixture()["zoom1"])
        #expect(event.conferenceURL == URL(string: "https://zoom.us/j/123456789"))
        #expect(event.selfResponseStatus == .tentative)
    }

    @Test("No conference data, no title, empty location")
    func plain() throws {
        let event = try #require(try decodeFixture()["plain1"])
        #expect(event.conferenceURL == nil)
        #expect(event.title == "")
        #expect(event.location == nil)
        #expect(event.description == nil)
        #expect(event.selfResponseStatus == .needsAction)
    }

    @Test("Deleted events without times are dropped")
    func deleted() throws {
        #expect(try decodeFixture()["deleted-no-times"] == nil)
        #expect(try decodeFixture().count == 6)
    }
}

@Suite("GoogleCalendarClient")
struct GoogleCalendarClientTests {
    let from = Date(timeIntervalSince1970: 1_795_478_400) // 2026-11-24T00:00:00Z
    var to: Date { from.addingTimeInterval(86_400) }

    @Test("Lists calendars across pages")
    func calendars() async throws {
        let transport = StubTransport { request in
            #expect(request.url?.path == "/calendar/v3/users/me/calendarList")
            #expect(queryItems(request.url!)["showHidden"] == "true")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
            if queryItems(request.url!)["pageToken"] == "p2" {
                return (200, [:], json(##"{"items":[{"id":"team@group.calendar.google.com","summary":"Team","summaryOverride":"My Team","backgroundColor":"#9fe1e7","hidden":true},{"id":"gone","summary":"Gone","deleted":true}]}"##))
            }
            return (200, [:], json(##"{"items":[{"id":"me@example.com","summary":"me@example.com","backgroundColor":"#4986e7","primary":true,"selected":true}],"nextPageToken":"p2"}"##))
        }
        let calendars = try await makeClient(transport).calendars()
        #expect(calendars == [
            GoogleCalendar(id: "me@example.com", name: "me@example.com", colorHex: "#4986e7", isPrimary: true, isSelected: true),
            GoogleCalendar(id: "team@group.calendar.google.com", name: "My Team", colorHex: "#9fe1e7", isPrimary: false, isSelected: false, isHidden: true),
        ])
        #expect(transport.requests.count == 2)
    }

    @Test("Event requests use singleEvents, startTime order and a padded time range")
    func eventQuery() async throws {
        let transport = StubTransport { _ in (200, [:], json(#"{"items":[]}"#)) }
        _ = try await makeClient(transport).events(calendarIDs: ["primary"], from: from, to: to)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/calendar/v3/calendars/primary/events")
        let query = queryItems(request.url!)
        #expect(query["singleEvents"] == "true")
        #expect(query["orderBy"] == "startTime")
        // Padded by 26 h on both sides so all-day events in other calendar time zones are found.
        #expect(query["timeMin"] == "2026-11-22T22:00:00Z")
        #expect(query["timeMax"] == "2026-11-26T02:00:00Z")
        #expect(query["maxResults"] == "250")
        #expect(query["showDeleted"] == nil)
        #expect(query["pageToken"] == nil)
    }

    @Test("Calendar IDs are percent-encoded in the path")
    func calendarIDEncoding() {
        let url = GoogleCalendarClient.url(path: ["calendars", "en.japanese#holiday@group.v.calendar.google.com", "events"], query: [])
        #expect(url.absoluteString == "https://www.googleapis.com/calendar/v3/calendars/en.japanese%23holiday%40group.v.calendar.google.com/events")
        #expect(url.path == "/calendar/v3/calendars/en.japanese#holiday@group.v.calendar.google.com/events")
    }

    @Test("Follows nextPageToken until the last page")
    func paging() async throws {
        let transport = StubTransport { request in
            let token = queryItems(request.url!)["pageToken"]
            func item(_ id: String, _ hour: Int) -> String {
                #"{"id":"\#(id)","status":"confirmed","summary":"\#(id)","start":{"dateTime":"2026-11-24T\#(String(format: "%02d", hour)):00:00Z"},"end":{"dateTime":"2026-11-24T\#(String(format: "%02d", hour)):30:00Z"}}"#
            }
            switch token {
            case nil: return (200, [:], json(#"{"items":[\#(item("a", 1)),\#(item("b", 2))],"nextPageToken":"t+2/=="}"#))
            case "t+2/==": return (200, [:], json(#"{"items":[\#(item("c", 3))],"nextPageToken":"t3"}"#))
            case "t3": return (200, [:], json(#"{"items":[\#(item("d", 4))]}"#))
            default: return (400, [:], Data())
            }
        }
        let events = try await makeClient(transport, pageSize: 2).events(calendarIDs: ["primary"], from: from, to: to)
        #expect(events.map(\.id) == ["a", "b", "c", "d"])
        #expect(transport.requests.count == 3)
        // A page token containing + / = survives encoding.
        #expect(transport.requests[1].url?.query(percentEncoded: true)?.contains("pageToken=t%2B2%2F%3D%3D") == true)
        #expect(queryItems(transport.requests[0].url!)["maxResults"] == "2")
    }

    @Test("Merges calendars sorted by start and omits cancelled events by default")
    func merge() async throws {
        let transport = StubTransport { request in
            if request.url!.path.contains("work") {
                return (200, [:], json(#"{"items":[{"id":"w1","status":"confirmed","start":{"dateTime":"2026-11-24T05:00:00Z"},"end":{"dateTime":"2026-11-24T06:00:00Z"}},{"id":"w2","status":"cancelled","start":{"dateTime":"2026-11-24T06:00:00Z"},"end":{"dateTime":"2026-11-24T07:00:00Z"}}]}"#))
            }
            return (200, [:], json(#"{"items":[{"id":"p1","status":"confirmed","start":{"dateTime":"2026-11-24T03:00:00Z"},"end":{"dateTime":"2026-11-24T04:00:00Z"}},{"id":"p2","status":"confirmed","start":{"dateTime":"2026-11-24T08:00:00Z"},"end":{"dateTime":"2026-11-24T09:00:00Z"}}]}"#))
        }
        let client = makeClient(transport)
        let events = try await client.events(calendarIDs: Set(["primary", "work", "primary"]), from: from, to: to)
        #expect(events.map(\.id) == ["p1", "w1", "p2"])
        #expect(events.map(\.calendarID) == ["primary", "work", "primary"])
        #expect(transport.requests.count == 2)

        let withCancelled = try await client.events(calendarIDs: ["work"], from: from, to: to, includeCancelled: true)
        #expect(withCancelled.map(\.id) == ["w1", "w2"])
        #expect(withCancelled.last?.isCancelled == true)
        #expect(queryItems(transport.requests.last!.url!)["showDeleted"] == "true")
    }

    @Test("No calendar IDs means no requests")
    func empty() async throws {
        let transport = StubTransport { _ in (500, [:], Data()) }
        #expect(try await makeClient(transport).events(calendarIDs: [String](), from: from, to: to).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test("401 forces one token refresh and retries")
    func unauthorizedRetry() async throws {
        let tokens = StubTokens()
        let transport = StubTransport { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" {
                return (401, [:], json(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#))
            }
            return (200, [:], json(#"{"items":[]}"#))
        }
        _ = try await makeClient(transport, tokens: tokens).calendars()
        #expect(tokens.forcedRefreshes == 1)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test("A second 401 throws unauthorized")
    func unauthorizedTwice() async throws {
        let tokens = StubTokens()
        let transport = StubTransport { _ in (401, [:], Data()) }
        await #expect(throws: GoogleCalendarError.unauthorized) { try await makeClient(transport, tokens: tokens).calendars() }
        #expect(tokens.forcedRefreshes == 1)
        #expect(transport.requests.count == 2)
    }

    @Test("429 is retried with backoff, then reported as rateLimited")
    func rateLimited() async throws {
        let sleeps = Recorder<Duration>()
        let transport = StubTransport { _ in (429, ["Retry-After": "2"], json(#"{"error":{"code":429,"message":"Rate Limit Exceeded"}}"#)) }
        await #expect(throws: GoogleCalendarError.rateLimited(retryAfter: 2)) {
            try await makeClient(transport, sleeps: sleeps).calendars()
        }
        #expect(transport.requests.count == 3)
        #expect(sleeps.values == [.seconds(2), .seconds(2)])
    }

    @Test("403 rateLimitExceeded recovers after a retry")
    func forbiddenRateLimitRecovers() async throws {
        let calls = Recorder<Int>()
        let sleeps = Recorder<Duration>()
        let transport = StubTransport { _ in
            let n = calls.record(1)
            if n == 1 {
                return (403, [:], json(#"{"error":{"code":403,"message":"Rate Limit Exceeded","errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}"#))
            }
            return (200, [:], json(#"{"items":[]}"#))
        }
        let retry = RetryPolicy(maxRetries: 2, baseDelay: .milliseconds(100))
        #expect(try await makeClient(transport, retry: retry, sleeps: sleeps).calendars().isEmpty)
        #expect(sleeps.values == [.milliseconds(100)])
    }

    @Test("Other 403s are forbidden and not retried")
    func forbidden() async throws {
        let transport = StubTransport { _ in
            (403, [:], json(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"reason":"insufficientPermissions"}]}}"#))
        }
        await #expect(throws: GoogleCalendarError.forbidden(reason: "insufficientPermissions", message: "Request had insufficient authentication scopes.")) {
            try await makeClient(transport).calendars()
        }
        #expect(transport.requests.count == 1)
    }

    @Test("404 maps to notFound")
    func notFound() async throws {
        let transport = StubTransport { _ in (404, [:], json(#"{"error":{"code":404,"message":"Not Found"}}"#)) }
        await #expect(throws: GoogleCalendarError.notFound(message: "Not Found")) {
            try await makeClient(transport).events(calendarIDs: ["missing"], from: from, to: to)
        }
    }

    @Test("5xx is retried with exponential backoff")
    func serverErrors() async throws {
        let sleeps = Recorder<Duration>()
        let transport = StubTransport { _ in (503, [:], Data()) }
        let retry = RetryPolicy(maxRetries: 3, baseDelay: .milliseconds(100), maxDelay: .milliseconds(250))
        await #expect(throws: GoogleCalendarError.http(status: 503, message: nil)) {
            try await makeClient(transport, retry: retry, sleeps: sleeps).calendars()
        }
        #expect(sleeps.values == [.milliseconds(100), .milliseconds(200), .milliseconds(250)])
    }

    @Test("Offline transport errors map to offline")
    func offline() async throws {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut] {
            let transport = StubTransport { _ in throw URLError(code) }
            await #expect(throws: GoogleCalendarError.offline) { try await makeClient(transport).calendars() }
        }
    }

    @Test("Not signed in propagates from the token provider")
    @MainActor
    func notSignedIn() async throws {
        let auth = GoogleAuth(configuration: testConfiguration, store: InMemoryCredentialStore(),
                              transport: StubTransport { _ in (500, [:], Data()) }, userAgent: StubUserAgent())
        let client = GoogleCalendarClient(auth: auth, transport: StubTransport { _ in (200, [:], Data()) })
        await #expect(throws: GoogleCalendarError.notSignedIn) { try await client.calendars() }
    }

    @Test("All-day events from a calendar in another time zone are matched in allDayTimeZone")
    func allDayAcrossTimeZones() async throws {
        // Seoul morning: 2026-11-24 00:00–12:00 KST = 2026-11-23T15:00Z – 2026-11-24T03:00Z.
        let morningStart = Date(timeIntervalSince1970: 1_795_478_400 - 9 * 3600)
        let morningEnd = morningStart.addingTimeInterval(12 * 3600)
        let transport = StubTransport { _ in
            (200, [:], json(#"""
            {"timeZone":"America/Los_Angeles","items":[
              {"id":"today","status":"confirmed","start":{"date":"2026-11-24"},"end":{"date":"2026-11-25"}},
              {"id":"yesterday","status":"confirmed","start":{"date":"2026-11-23"},"end":{"date":"2026-11-24"}},
              {"id":"timed-before","status":"confirmed","start":{"dateTime":"2026-11-23T10:00:00Z"},"end":{"dateTime":"2026-11-23T11:00:00Z"}},
              {"id":"timed-inside","status":"confirmed","start":{"dateTime":"2026-11-24T01:00:00Z"},"end":{"dateTime":"2026-11-24T02:00:00Z"}},
              {"id":"timed-after","status":"confirmed","start":{"dateTime":"2026-11-24T03:00:00Z"},"end":{"dateTime":"2026-11-24T04:00:00Z"}}
            ]}
            """#))
        }
        let events = try await makeClient(transport).events(calendarIDs: ["la@example.com"], from: morningStart, to: morningEnd)
        #expect(events.map(\.id) == ["today", "timed-inside"])
    }

    @Test("Overlap matches the API's timeMin/timeMax rule")
    func overlapRule() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func event(_ start: TimeInterval, _ end: TimeInterval) -> GoogleCalendarEvent {
            GoogleCalendarEvent(id: "e", calendarID: "c", title: "", start: base + start, end: base + end, isAllDay: false,
                                isCancelled: false, selfResponseStatus: .none, conferenceURL: nil, location: nil,
                                description: nil, htmlLink: nil)
        }
        let from = base + 100, to = base + 200
        #expect(GoogleCalendarClient.overlaps(event(50, 150), from: from, to: to))
        #expect(GoogleCalendarClient.overlaps(event(150, 250), from: from, to: to))
        #expect(!GoogleCalendarClient.overlaps(event(50, 100), from: from, to: to))
        #expect(!GoogleCalendarClient.overlaps(event(200, 250), from: from, to: to))
        #expect(GoogleCalendarClient.overlaps(event(100, 100), from: from, to: to))
        #expect(!GoogleCalendarClient.overlaps(event(99, 99), from: from, to: to))
    }

    @Test("Hitting the page limit reports tooManyResults instead of partial data")
    func pageLimit() async throws {
        let transport = StubTransport { _ in (200, [:], json(#"{"items":[],"nextPageToken":"more"}"#)) }
        await #expect(throws: GoogleCalendarError.tooManyResults) {
            try await makeClient(transport).events(calendarIDs: ["primary"], from: from, to: to)
        }
        #expect(transport.requests.count == GoogleCalendarClient.maxPages)
        await #expect(throws: GoogleCalendarError.tooManyResults) { try await makeClient(transport).calendars() }
    }

    @Test("A huge Retry-After is not waited for and does not trap")
    func hugeRetryAfter() async throws {
        let sleeps = Recorder<Duration>()
        let transport = StubTransport { _ in (429, ["Retry-After": "1e30"], Data()) }
        await #expect(throws: GoogleCalendarError.rateLimited(retryAfter: 1e30)) {
            try await makeClient(transport, sleeps: sleeps).calendars()
        }
        #expect(sleeps.values.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test("Invalid Retry-After values fall back to exponential backoff", arguments: ["inf", "nan", "-5", "soon", "1e400"])
    func invalidRetryAfter(header: String) async throws {
        let sleeps = Recorder<Duration>()
        let transport = StubTransport { _ in (429, ["Retry-After": header], Data()) }
        let retry = RetryPolicy(maxRetries: 2, baseDelay: .milliseconds(100))
        await #expect(throws: GoogleCalendarError.rateLimited(retryAfter: nil)) {
            try await makeClient(transport, retry: retry, sleeps: sleeps).calendars()
        }
        #expect(sleeps.values == [.milliseconds(100), .milliseconds(200)])
    }
}
