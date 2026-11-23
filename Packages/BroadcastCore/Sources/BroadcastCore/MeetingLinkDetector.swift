import Foundation

/// An online meeting provider recognised in free text (location / notes).
public struct MeetingProvider: Sendable, Equatable {
    public let name: String
    /// Hosts that belong to the provider. A URL matches when its host equals one of these
    /// or is a subdomain of it (`company.zoom.us` matches `zoom.us`).
    public let hosts: [String]
    /// If non-empty, the URL path must start with one of these (case-insensitive) so that,
    /// e.g., a link to a provider's marketing page is not mistaken for a meeting.
    public let pathPrefixes: [String]

    public init(name: String, hosts: [String], pathPrefixes: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.pathPrefixes = pathPrefixes
    }

    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return false }
        let hostMatches = hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        guard hostMatches else { return false }
        let path = url.path().lowercased()
        if pathPrefixes.isEmpty {
            // Require *something* after the host: a bare domain is never a meeting room.
            return path.count > 1
        }
        return pathPrefixes.contains { path.hasPrefix($0) }
    }
}

/// Decides whether a meeting has an online meeting link and exposes that link.
public enum MeetingLinkDetector {
    /// The single list of known providers. Add new providers here.
    public static let providers: [MeetingProvider] = [
        MeetingProvider(name: "Zoom", hosts: ["zoom.us", "zoom.com", "zoomgov.com"],
                        pathPrefixes: ["/j/", "/my/", "/s/", "/w/", "/wc/", "/meeting/"]),
        MeetingProvider(name: "Google Meet", hosts: ["meet.google.com"]),
        MeetingProvider(name: "Microsoft Teams", hosts: ["teams.microsoft.com", "teams.live.com", "teams.microsoft.us"],
                        pathPrefixes: ["/l/meetup-join/", "/meet/", "/v2/", "/dl/launcher/"]),
        MeetingProvider(name: "Webex", hosts: ["webex.com"]),
        MeetingProvider(name: "Whereby", hosts: ["whereby.com"]),
        MeetingProvider(name: "Around", hosts: ["around.co"]),
        MeetingProvider(name: "Jitsi", hosts: ["meet.jit.si", "8x8.vc"]),
        MeetingProvider(name: "GoTo Meeting", hosts: ["gotomeeting.com", "gotomeet.me", "meet.goto.com"]),
        MeetingProvider(name: "GoTo", hosts: ["app.goto.com"], pathPrefixes: ["/meeting/"]),
        MeetingProvider(name: "BlueJeans", hosts: ["bluejeans.com"]),
        MeetingProvider(name: "Slack Huddle", hosts: ["app.slack.com", "slack.com"], pathPrefixes: ["/huddle/"]),
        MeetingProvider(name: "Amazon Chime", hosts: ["chime.aws"]),
        MeetingProvider(name: "RingCentral", hosts: ["meetings.ringcentral.com", "v.ringcentral.com", "video.ringcentral.com"]),
        MeetingProvider(name: "Skype", hosts: ["join.skype.com"]),
        MeetingProvider(name: "Gather", hosts: ["app.gather.town"]),
        MeetingProvider(name: "Discord", hosts: ["discord.gg"]),
        MeetingProvider(name: "Pop", hosts: ["pop.com"], pathPrefixes: ["/j/"]),
        MeetingProvider(name: "Tuple", hosts: ["tuple.app"], pathPrefixes: ["/c/"]),
        MeetingProvider(name: "Zoho Meeting", hosts: ["meeting.zoho.com", "meeting.zoho.eu"]),
        MeetingProvider(name: "Livestorm", hosts: ["app.livestorm.co"]),
    ]

    /// Whether the meeting has an online meeting link.
    public static func hasMeetingLink(_ meeting: Meeting) -> Bool {
        meetingLink(for: meeting) != nil
    }

    /// The meeting link: `conferenceURL` if set, else the first known-provider URL in
    /// `location`, else in `notes`.
    public static func meetingLink(for meeting: Meeting) -> URL? {
        if let url = meeting.conferenceURL { return url }
        if let location = meeting.location, let url = providerURL(in: location) { return url }
        if let notes = meeting.notes, let url = providerURL(in: notes) { return url }
        return nil
    }

    /// The first URL in `text` that belongs to a known provider.
    public static func providerURL(in text: String) -> URL? {
        urls(in: text).first { provider(for: $0) != nil }
    }

    /// The known provider a URL belongs to, if any.
    public static func provider(for url: URL) -> MeetingProvider? {
        providers.first { $0.matches(url) }
    }

    /// All web links found in `text`, in order of appearance.
    static func urls(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }
}
