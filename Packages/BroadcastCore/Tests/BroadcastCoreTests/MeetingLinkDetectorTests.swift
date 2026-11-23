import Foundation
import Testing
@testable import BroadcastCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func meeting(
    conferenceURL: URL? = nil, location: String? = nil, notes: String? = nil,
    allDay: Bool = false, cancelled: Bool = false, declined: Bool = false
) -> Meeting {
    Meeting(id: "m", title: "Sync", start: t0, end: t0.addingTimeInterval(1800),
            isAllDay: allDay, isCancelled: cancelled, isDeclinedBySelf: declined,
            conferenceURL: conferenceURL, location: location, notes: notes)
}

@Suite struct MeetingLinkDetectorTests {
    @Test func conferenceURLWins() {
        let url = URL(string: "https://example.com/any-room")!
        let m = meeting(conferenceURL: url, location: "https://zoom.us/j/1")
        #expect(MeetingLinkDetector.meetingLink(for: m) == url)
        #expect(MeetingLinkDetector.hasMeetingLink(m))
        #expect(m.meetingLink == url)
    }

    @Test func noLinkAnywhere() {
        let m = meeting(location: "Room 4B", notes: "Agenda: see https://docs.example.com/agenda")
        #expect(MeetingLinkDetector.meetingLink(for: m) == nil)
        #expect(!MeetingLinkDetector.hasMeetingLink(m))
    }

    @Test(arguments: [
        "https://us02web.zoom.us/j/123456789?pwd=abc",
        "https://zoom.us/my/someone",
        "https://meet.google.com/abc-defg-hij",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x",
        "https://teams.live.com/meet/9123456789",
        "https://acme.webex.com/acme/j.php?MTID=m123",
        "https://whereby.com/team-room",
        "https://around.co/r/team",
        "https://meet.jit.si/SomeRoom",
        "https://global.gotomeeting.com/join/123456789",
        "https://meet.goto.com/123456789",
        "https://app.goto.com/meeting/123456789",
        "https://bluejeans.com/123456789",
        "https://app.slack.com/huddle/T123/C456",
        "https://chime.aws/1234567890",
        "https://meetings.ringcentral.com/j/123",
    ])
    func detectsProviderInLocation(_ link: String) {
        let m = meeting(location: link)
        #expect(MeetingLinkDetector.meetingLink(for: m) == URL(string: link))
    }

    @Test func detectsProviderInNotesAmongOtherText() {
        let notes = """
        Agenda: https://docs.example.com/agenda
        Join Zoom Meeting
        https://acme.zoom.us/j/987654321?pwd=xyz
        Meeting ID: 987 654 321
        """
        let m = meeting(location: "HQ, Room 1", notes: notes)
        #expect(MeetingLinkDetector.meetingLink(for: m)?.absoluteString == "https://acme.zoom.us/j/987654321?pwd=xyz")
    }

    @Test func detectsLinkInsideHTMLNotes() {
        let notes = #"<p>Join: <a href="https://meet.google.com/xyz-abcd-efg">Google Meet</a></p>"#
        let m = meeting(notes: notes)
        #expect(MeetingLinkDetector.meetingLink(for: m)?.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }

    @Test func locationIsPreferredOverNotes() {
        let m = meeting(location: "https://meet.google.com/aaa-bbbb-ccc", notes: "https://zoom.us/j/1")
        #expect(MeetingLinkDetector.meetingLink(for: m)?.host() == "meet.google.com")
    }

    @Test(arguments: [
        "https://zoom.us/pricing",
        "https://zoom.us",
        "https://meet.google.com/",
        "https://teams.microsoft.com/",
        "https://slack.com/intl/en-gb/",
        "https://notzoom.us/j/123",
        "ftp://meet.google.com/abc",
        "https://evil.com/meet.google.com/abc",
    ])
    func ignoresNonMeetingLinks(_ link: String) {
        #expect(MeetingLinkDetector.meetingLink(for: meeting(location: link)) == nil)
    }

    @Test func providerListIsSingleSourceAndNamed() {
        let names = MeetingLinkDetector.providers.map(\.name)
        for expected in ["Zoom", "Google Meet", "Microsoft Teams", "Webex", "Whereby", "Around",
                         "Jitsi", "GoTo Meeting", "BlueJeans", "Slack Huddle"] {
            #expect(names.contains(expected))
        }
        #expect(MeetingLinkDetector.provider(for: URL(string: "https://meet.google.com/a-b-c")!)?.name == "Google Meet")
    }
}

@Suite struct QualifyingTests {
    private let link = URL(string: "https://meet.google.com/abc-defg-hij")!

    @Test func qualifiesWithLink() {
        #expect(meeting(conferenceURL: link).isQualifying)
        #expect(meeting(notes: "https://zoom.us/j/1").isQualifying)
    }

    @Test func withoutLinkDoesNotQualify() {
        #expect(!meeting(location: "Room 1").isQualifying)
    }

    @Test func allDayCancelledDeclinedDoNotQualify() {
        #expect(!meeting(conferenceURL: link, allDay: true).isQualifying)
        #expect(!meeting(conferenceURL: link, cancelled: true).isQualifying)
        #expect(!meeting(conferenceURL: link, declined: true).isQualifying)
    }

    @Test func inProgress() {
        let m = meeting(conferenceURL: link)
        #expect(m.isInProgress(at: t0))
        #expect(m.isInProgress(at: t0.addingTimeInterval(1799)))
        #expect(!m.isInProgress(at: t0.addingTimeInterval(1800)))
        #expect(!m.isInProgress(at: t0.addingTimeInterval(-1)))
    }
}
