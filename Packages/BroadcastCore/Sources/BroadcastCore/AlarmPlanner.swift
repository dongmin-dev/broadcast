import Foundation

/// How the menu-bar item flashes.
public enum FlashStyle: Sendable, Equatable {
    case none
    /// Solid red background, slow flashing (remaining <= `AlarmPlanner.slowFlashThreshold`).
    case slow
    /// Solid red background, fast flashing (remaining <= `AlarmPlanner.fastFlashThreshold`).
    case fast
}

/// What the audio player should be doing.
public enum AudioCommand: Sendable, Equatable {
    /// No tune should be playing. Stop any tune that is still playing.
    case none
    /// The tune for `meetingID` should be playing. If it is not already playing for that
    /// meeting, start it `offset` seconds into the file (so it ends exactly at the meeting
    /// start). If it is already playing for that meeting, leave it alone (never restart).
    case play(offset: TimeInterval, meetingID: Meeting.ID)
    /// The tune for `meetingID` is already playing (per `playingMeetingID`); leave it alone.
    case keepPlaying(meetingID: Meeting.ID)

    /// The meeting whose tune should be playing, if any.
    public var meetingID: Meeting.ID? {
        switch self {
        case .none: nil
        case .play(_, let id), .keepPlaying(let id): id
        }
    }
}

/// What the menu-bar item shows and plays at a given instant.
public struct AlarmPresentation: Sendable, Equatable {
    /// Menu-bar text. `nil` means icon only (idle).
    public var text: String?
    public var flash: FlashStyle
    public var audio: AudioCommand
    /// The next qualifying meeting that has not started yet (`start > now`), for the menu.
    public var nextMeeting: Meeting?
    /// When the app must call `presentation` again. `nil` = nothing scheduled (re-evaluate
    /// when the meeting list changes).
    public var nextWakeDate: Date?
    /// The meeting the text is about, if any.
    public var focusedMeetingID: Meeting.ID?

    public init(
        text: String? = nil,
        flash: FlashStyle = .none,
        audio: AudioCommand = .none,
        nextMeeting: Meeting? = nil,
        nextWakeDate: Date? = nil,
        focusedMeetingID: Meeting.ID? = nil
    ) {
        self.text = text
        self.flash = flash
        self.audio = audio
        self.nextMeeting = nextMeeting
        self.nextWakeDate = nextWakeDate
        self.focusedMeetingID = focusedMeetingID
    }

    public var isIdle: Bool { text == nil }
}

/// Pure planner: meetings + now + lead time -> what to show and play.
///
/// The alarm window of a qualifying meeting is `[start - lead, start)`.
/// A meeting *owns the sound* if, at the instant its window begins, no other qualifying
/// meeting is in progress and no other meeting's alarm is playing. Meetings that do not own
/// the sound get a silent, non-flashing "back-to-back" countdown instead.
public enum AlarmPlanner {
    /// Flash slowly once remaining time is at most this.
    public static let slowFlashThreshold: TimeInterval = 8
    /// Flash fast once remaining time is at most this.
    public static let fastFlashThreshold: TimeInterval = 3
    /// How long "<title> is live!" is shown after the start.
    public static let liveDuration: TimeInterval = 30
    /// Maximum number of characters of the title shown in the menu bar (including the ellipsis).
    public static let maxTitleLength = 30
    /// Shown when a meeting has an empty title.
    public static let untitledTitle = "Meeting"

    /// Absorbs floating-point noise when converting remaining time to whole seconds.
    static let epsilon: TimeInterval = 1e-6

    /// - Parameters:
    ///   - meetings: All known meetings, in any order; non-qualifying ones are ignored.
    ///   - now: The current instant.
    ///   - lead: Length of the tune; the alarm window starts `lead` seconds before the meeting.
    ///   - playingMeetingID: The meeting whose tune the player is currently playing, if the
    ///     caller tracks it. When it equals the sound owner, `.keepPlaying` is returned instead
    ///     of `.play`.
    public static func presentation(
        meetings: [Meeting],
        now: Date,
        lead: TimeInterval,
        playingMeetingID: Meeting.ID? = nil
    ) -> AlarmPresentation {
        let qualifying = meetings
            .filter(\.isQualifying)
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }

        let nextMeeting = qualifying.first { $0.start > now }
        let lead = max(lead, 0)
        let owners = soundOwners(qualifying, lead: lead)

        var result = AlarmPresentation(nextMeeting: nextMeeting)
        var countdownStart: Date?

        func inWindow(_ m: Meeting) -> Bool { lead > 0 && m.start.addingTimeInterval(-lead) <= now && now < m.start }

        if let owner = qualifying.first(where: { owners.contains($0.id) && inWindow($0) }) {
            // Normal alarm with sound.
            let remaining = owner.start.timeIntervalSince(now)
            let seconds = wholeSeconds(remaining)
            let elapsed = lead - remaining
            result.text = "\(displayTitle(owner.title)) in \(formatMinutesSeconds(seconds))"
            result.flash = flashStyle(remaining: remaining)
            result.audio = owner.id == playingMeetingID
                ? .keepPlaying(meetingID: owner.id)
                // Snap floating-point noise at the window start to exactly 0.
                : .play(offset: elapsed < epsilon ? 0 : elapsed, meetingID: owner.id)
            result.focusedMeetingID = owner.id
            countdownStart = owner.start
        } else if let quiet = qualifying.first(where: { !owners.contains($0.id) && inWindow($0) }) {
            // Back-to-back: silent countdown, no flash.
            let seconds = wholeSeconds(quiet.start.timeIntervalSince(now))
            let unit = seconds == 1 ? "second" : "seconds"
            result.text = "\(displayTitle(quiet.title)) in \(seconds) \(unit)..."
            result.focusedMeetingID = quiet.id
            countdownStart = quiet.start
        } else if let live = qualifying.last(where: { $0.start <= now && now < $0.start.addingTimeInterval(liveDuration) }) {
            result.text = "\(displayTitle(live.title)) is live!"
            result.focusedMeetingID = live.id
        }

        // Next instant at which anything above can change.
        var candidates: [Date] = []
        for m in qualifying {
            if lead > 0 { candidates.append(m.start.addingTimeInterval(-lead)) }
            candidates.append(m.start)
            candidates.append(m.start.addingTimeInterval(liveDuration))
        }
        if let start = countdownStart {
            // When the displayed whole-second count ticks down.
            let seconds = wholeSeconds(start.timeIntervalSince(now))
            candidates.append(start.addingTimeInterval(-TimeInterval(seconds - 1)))
        }
        result.nextWakeDate = candidates.filter { $0 > now }.min()
        return result
    }

    /// IDs of the qualifying meetings that own the sound (see type docs). Deterministic:
    /// decided in order of window start, ties broken by meeting id.
    static func soundOwners(_ qualifying: [Meeting], lead: TimeInterval) -> Set<Meeting.ID> {
        guard lead > 0 else { return [] }
        var owners: [Meeting] = []
        for m in qualifying { // sorted by (start, id) == sorted by (window start, id)
            let windowStart = m.start.addingTimeInterval(-lead)
            let otherInProgress = qualifying.contains { $0.id != m.id && $0.isInProgress(at: windowStart) }
            let alarmPlaying = owners.contains { $0.start.addingTimeInterval(-lead) <= windowStart && windowStart < $0.start }
            if !otherInProgress && !alarmPlaying { owners.append(m) }
        }
        return Set(owners.map(\.id))
    }

    /// The flash style for a sounding alarm with `remaining` seconds to go.
    public static func flashStyle(remaining: TimeInterval) -> FlashStyle {
        if remaining <= fastFlashThreshold + epsilon { return .fast }
        if remaining <= slowFlashThreshold + epsilon { return .slow }
        return .none
    }

    /// The title as shown in the menu bar: trimmed, and truncated with "…" to `maxTitleLength`.
    public static func displayTitle(_ title: String) -> String {
        let trimmed = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return untitledTitle }
        guard trimmed.count > maxTitleLength else { return trimmed }
        let head = trimmed.prefix(maxTitleLength - 1).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    /// Remaining time rounded up to whole seconds (a countdown shows 0:01 until the start).
    static func wholeSeconds(_ remaining: TimeInterval) -> Int {
        max(0, Int((remaining - epsilon).rounded(.up)))
    }

    /// `m:ss`, e.g. 16 -> "0:16", 95 -> "1:35".
    static func formatMinutesSeconds(_ seconds: Int) -> String {
        let s = seconds % 60
        return "\(seconds / 60):" + (s < 10 ? "0\(s)" : "\(s)")
    }
}
