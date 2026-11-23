import Foundation

/// A calendar event as Broadcast sees it.
public struct Meeting: Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var isDeclinedBySelf: Bool
    /// Explicit conference link supplied by the calendar provider (e.g. Google `hangoutLink`/`conferenceData`).
    public var conferenceURL: URL?
    public var location: String?
    public var notes: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        isDeclinedBySelf: Bool = false,
        conferenceURL: URL? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.isDeclinedBySelf = isDeclinedBySelf
        self.conferenceURL = conferenceURL
        self.location = location
        self.notes = notes
    }
}

extension Meeting {
    /// The online meeting link, if any (see `MeetingLinkDetector`).
    public var meetingLink: URL? { MeetingLinkDetector.meetingLink(for: self) }

    /// Whether Broadcast plays an alarm for this meeting: it has a meeting link and is not
    /// all-day, cancelled, or declined by the user.
    public var isQualifying: Bool {
        !isAllDay && !isCancelled && !isDeclinedBySelf && meetingLink != nil
    }

    /// Whether the meeting is in progress at `date` (`start <= date < end`).
    public func isInProgress(at date: Date) -> Bool {
        start <= date && date < end
    }
}
