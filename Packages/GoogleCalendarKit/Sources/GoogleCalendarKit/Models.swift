import Foundation

/// A calendar from the user's calendar list.
public struct GoogleCalendar: Sendable, Hashable, Identifiable {
    public var id: String
    /// The user's override name if set, otherwise the calendar's title.
    public var name: String
    /// Background colour as a hex string such as `#9fe1e7`.
    public var colorHex: String?
    public var isPrimary: Bool
    /// Whether the calendar's events are shown in the Google Calendar UI.
    public var isSelected: Bool
    /// Whether the user hid the calendar from the calendar list in Google Calendar.
    public var isHidden: Bool

    public init(id: String, name: String, colorHex: String?, isPrimary: Bool, isSelected: Bool, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isPrimary = isPrimary
        self.isSelected = isSelected
        self.isHidden = isHidden
    }
}

/// The signed-in user's response to an event invitation.
public enum ResponseStatus: String, Sendable, Hashable, Codable {
    case accepted, declined, tentative, needsAction
    /// The user is not an attendee (e.g. their own event without guests).
    case none
}

/// One event (or one instance of a recurring event).
public struct GoogleCalendarEvent: Sendable, Hashable, Identifiable {
    public var id: String
    public var calendarID: String
    /// iCalendar UID; the same event seen through two calendars shares it.
    public var iCalUID: String?
    public var title: String
    public var start: Date
    /// Exclusive end. For all-day events this is midnight after the last day.
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var selfResponseStatus: ResponseStatus
    /// Google Meet `hangoutLink`, or the `video` entry point of `conferenceData`.
    public var conferenceURL: URL?
    public var location: String?
    public var description: String?
    public var htmlLink: URL?

    public init(
        id: String, calendarID: String, iCalUID: String? = nil, title: String, start: Date, end: Date,
        isAllDay: Bool, isCancelled: Bool, selfResponseStatus: ResponseStatus,
        conferenceURL: URL?, location: String?, description: String?, htmlLink: URL?
    ) {
        self.id = id
        self.calendarID = calendarID
        self.iCalUID = iCalUID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.selfResponseStatus = selfResponseStatus
        self.conferenceURL = conferenceURL
        self.location = location
        self.description = description
        self.htmlLink = htmlLink
    }
}

// MARK: - Wire format (Calendar API v3)

struct CalendarListPage: Decodable {
    struct Entry: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let backgroundColor: String?
        let primary: Bool?
        let selected: Bool?
        let hidden: Bool?
        let deleted: Bool?
    }

    let items: [Entry]?
    let nextPageToken: String?
}

extension GoogleCalendar {
    init(_ entry: CalendarListPage.Entry) {
        self.init(
            id: entry.id,
            name: entry.summaryOverride ?? entry.summary ?? entry.id,
            colorHex: entry.backgroundColor,
            isPrimary: entry.primary ?? false,
            isSelected: entry.selected ?? false,
            isHidden: entry.hidden ?? false
        )
    }
}

struct EventsPage: Decodable {
    let items: [EventResource]?
    let nextPageToken: String?
    let timeZone: String?
}

struct EventResource: Decodable {
    struct EventDateTime: Decodable {
        let date: String?
        let dateTime: String?
        let timeZone: String?
    }

    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }

    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }

        let entryPoints: [EntryPoint]?
    }

    let id: String
    let iCalUID: String?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: EventDateTime?
    let end: EventDateTime?
    let attendees: [Attendee]?
    let conferenceData: ConferenceData?
}

enum EventMapping {
    /// Converts an API event. Returns `nil` for events without a usable start (e.g.
    /// deleted events, which only carry an id and status).
    static func event(
        from resource: EventResource,
        calendarID: String,
        allDayTimeZone: TimeZone
    ) -> GoogleCalendarEvent? {
        guard let startValue = resource.start,
              let (start, isAllDay) = parse(startValue, allDayTimeZone: allDayTimeZone)
        else { return nil }
        let end = resource.end.flatMap { parse($0, allDayTimeZone: allDayTimeZone)?.0 }
            ?? (isAllDay ? start.addingTimeInterval(86_400) : start)

        let selfStatus = resource.attendees?
            .first { $0.isSelf == true }?
            .responseStatus
            .flatMap(ResponseStatus.init(rawValue:)) ?? ResponseStatus.none

        let videoEntry = resource.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        let conference = (resource.hangoutLink ?? videoEntry).flatMap { URL(string: $0) }

        return GoogleCalendarEvent(
            id: resource.id,
            calendarID: calendarID,
            iCalUID: resource.iCalUID,
            title: resource.summary ?? "",
            start: start,
            end: end,
            isAllDay: isAllDay,
            isCancelled: resource.status == "cancelled",
            selfResponseStatus: selfStatus,
            conferenceURL: conference,
            location: resource.location.flatMap { $0.isEmpty ? nil : $0 },
            description: resource.description.flatMap { $0.isEmpty ? nil : $0 },
            htmlLink: resource.htmlLink.flatMap { URL(string: $0) }
        )
    }

    static func parse(_ value: EventResource.EventDateTime, allDayTimeZone: TimeZone) -> (Date, Bool)? {
        if let dateTime = value.dateTime {
            return RFC3339.date(from: dateTime).map { ($0, false) }
        }
        if let date = value.date {
            return RFC3339.allDayDate(from: date, timeZone: allDayTimeZone).map { ($0, true) }
        }
        return nil
    }
}

enum RFC3339 {
    static func date(from string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? withFraction.parse(string)
    }

    /// `yyyy-MM-dd` at local midnight in `timeZone`.
    static func allDayDate(from string: String, timeZone: TimeZone) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func string(from date: Date) -> String {
        date.formatted(.iso8601)
    }
}
