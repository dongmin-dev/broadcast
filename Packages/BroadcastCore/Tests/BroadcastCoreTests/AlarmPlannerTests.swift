import Foundation
import Testing
@testable import BroadcastCore

private let lead: TimeInterval = 95.04
private let base = Date(timeIntervalSinceReferenceDate: 800_000_000) // a 10:00:00-ish anchor
private let link = URL(string: "https://meet.google.com/abc-defg-hij")!

/// A qualifying meeting starting `startOffset` seconds after `base`.
private func mtg(_ id: String, _ title: String? = nil, at startOffset: TimeInterval,
                 minutes: Double = 30, link: URL? = link,
                 allDay: Bool = false, cancelled: Bool = false, declined: Bool = false) -> Meeting {
    Meeting(id: id, title: title ?? id, start: base.addingTimeInterval(startOffset),
            end: base.addingTimeInterval(startOffset + minutes * 60),
            isAllDay: allDay, isCancelled: cancelled, isDeclinedBySelf: declined, conferenceURL: link)
}

/// `base + seconds`.
private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private func plan(_ meetings: [Meeting], _ now: TimeInterval, playing: String? = nil) -> AlarmPresentation {
    AlarmPlanner.presentation(meetings: meetings, now: at(now), lead: lead, playingMeetingID: playing)
}

@Suite struct IdleTests {
    @Test func noMeetings() {
        let p = plan([], 0)
        #expect(p == AlarmPresentation())
        #expect(p.isIdle)
    }

    @Test func idleBeforeWindowShowsNextMeetingAndWakesAtWindowStart() {
        let standup = mtg("standup", at: 3600)
        let p = plan([standup], 0)
        #expect(p.text == nil)
        #expect(p.flash == .none)
        #expect(p.audio == .none)
        #expect(p.nextMeeting == standup)
        #expect(p.nextWakeDate == at(3600 - lead))
    }

    @Test func nextMeetingIsEarliestUpcomingQualifying() {
        let later = mtg("later", at: 7200)
        let sooner = mtg("sooner", at: 3600)
        let noLink = mtg("nolink", at: 1800, link: nil)
        let cancelled = mtg("cancelled", at: 900, cancelled: true)
        let p = plan([later, noLink, sooner, cancelled], 0)
        #expect(p.nextMeeting == sooner)
    }

    @Test func nonQualifyingMeetingsNeverAlarm() {
        let ms = [
            mtg("a", at: 10, link: nil),
            mtg("b", at: 10, allDay: true),
            mtg("c", at: 10, cancelled: true),
            mtg("d", at: 10, declined: true),
        ]
        let p = plan(ms, 0)
        #expect(p.isIdle)
        #expect(p.audio == .none)
        #expect(p.nextMeeting == nil)
        #expect(p.nextWakeDate == nil)
    }

    @Test func backToIdleAfterLivePeriod() {
        let m = mtg("standup", at: 0)
        let p = plan([m], AlarmPlanner.liveDuration)
        #expect(p.isIdle)
        #expect(p.audio == .none)
        #expect(p.nextMeeting == nil)
        #expect(p.nextWakeDate == nil)
    }

    @Test func zeroLeadNeverAlarms() {
        let m = mtg("standup", at: 10)
        let p = AlarmPlanner.presentation(meetings: [m], now: base, lead: 0)
        #expect(p.isIdle)
        #expect(p.nextWakeDate == at(10))
    }
}

@Suite struct NormalAlarmTests {
    let standup = mtg("standup", "Standup", at: 0)

    @Test func windowStartPlaysFromBeginning() {
        let p = plan([standup], -lead)
        #expect(p.audio == .play(offset: 0, meetingID: "standup"))
        #expect(p.text == "Standup in 1:36") // 95.04 s rounds up
        #expect(p.flash == .none)
        #expect(p.focusedMeetingID == "standup")
        #expect(p.nextMeeting == standup)
    }

    @Test func justBeforeWindowIsIdle() {
        let p = plan([standup], -lead - 0.01)
        #expect(p.isIdle)
        #expect(p.nextWakeDate == at(-lead))
    }

    @Test func textExample() {
        let p = plan([standup], -16)
        #expect(p.text == "Standup in 0:16")
        let q = plan([standup], -15.5)
        #expect(q.text == "Standup in 0:16")
        #expect(plan([standup], -75).text == "Standup in 1:15")
    }

    @Test func lateEntryOffsetMakesTuneEndAtStart() throws {
        let p = plan([standup], -40)
        guard case let .play(offset, id) = p.audio else {
            Issue.record("expected play, got \(p.audio)"); return
        }
        #expect(id == "standup")
        #expect(abs(offset - (lead - 40)) < 1e-9)
        // offset + remaining == lead: the tune ends exactly at the start.
        #expect(abs(offset + 40 - lead) < 1e-9)
    }

    @Test func keepPlayingWhenAlreadyPlayingThatMeeting() {
        #expect(plan([standup], -40, playing: "standup").audio == .keepPlaying(meetingID: "standup"))
        if case .play = plan([standup], -40, playing: "other").audio {} else {
            Issue.record("expected play when another tune is playing")
        }
        #expect(plan([standup], -40, playing: "standup").audio.meetingID == "standup")
    }

    @Test func soundStopsAtStart() {
        #expect(plan([standup], 0).audio == .none)
        #expect(plan([standup], 0, playing: "standup").audio == .none)
    }

    @Test func wakesEverySecondOnWholeSecondBoundaries() {
        #expect(plan([standup], -16).nextWakeDate == at(-15))
        #expect(plan([standup], -15.5).nextWakeDate == at(-15))
        #expect(plan([standup], -0.2).nextWakeDate == at(0))
        // window start: 95.04 s left shows 1:36, next tick at 95 s left.
        #expect(plan([standup], -lead).nextWakeDate == at(-95))
    }

    @Test func countdownTicksThroughWholeWindow() {
        // Simulate the app following nextWakeDate: every tick decrements the shown seconds by one.
        var now = at(-lead)
        var shown: [String] = []
        while now < at(0) {
            let p = AlarmPlanner.presentation(meetings: [standup], now: now, lead: lead)
            shown.append(p.text!)
            now = p.nextWakeDate!
        }
        #expect(shown.count == 96)
        #expect(shown.first == "Standup in 1:36")
        #expect(shown.last == "Standup in 0:01")
        #expect(Set(shown).count == shown.count)
    }
}

@Suite struct FlashTests {
    let m = mtg("m", "Standup", at: 0)

    @Test func thresholds() {
        #expect(AlarmPlanner.slowFlashThreshold == 8)
        #expect(AlarmPlanner.fastFlashThreshold == 3)
    }

    @Test(arguments: [
        (-9.0, FlashStyle.none), (-8.01, .none), (-8.0, .slow), (-5.0, .slow),
        (-3.01, .slow), (-3.0, .fast), (-0.5, .fast),
    ])
    func flashByRemaining(now: TimeInterval, expected: FlashStyle) {
        #expect(plan([m], now).flash == expected)
    }

    @Test func noFlashWhenLive() {
        #expect(plan([m], 0).flash == .none)
        #expect(plan([m], 5).flash == .none)
    }
}

@Suite struct LiveTests {
    let m = mtg("m", "Standup", at: 0)

    @Test func liveForThirtySeconds() {
        #expect(AlarmPlanner.liveDuration == 30)
        for t in [0.0, 1, 15, 29.9] {
            let p = plan([m], t)
            #expect(p.text == "Standup is live!")
            #expect(p.flash == .none)
            #expect(p.audio == .none)
        }
        #expect(plan([m], 30).isIdle)
    }

    @Test func liveWakesAtEndOfLivePeriod() {
        #expect(plan([m], 0).nextWakeDate == at(30))
        #expect(plan([m], 12.3).nextWakeDate == at(30))
    }

    @Test func nextMeetingDuringLiveIsTheFollowingOne() {
        let next = mtg("next", at: 3600)
        #expect(plan([m, next], 5).nextMeeting == next)
    }

    @Test func liveEvenIfAppMissedTheAlarm() {
        // App launched after start: no alarm happened, still shows live text.
        #expect(plan([m], 10).text == "Standup is live!")
    }
}

@Suite struct BackToBackTests {
    @Test func windowBeginsWhileAnotherMeetingInProgress() {
        let first = mtg("first", "Planning", at: 0, minutes: 30)
        let second = mtg("second", "Review", at: 1800)
        // Second's window begins at 1800 - lead, while first is in progress.
        let p = plan([first, second], 1800 - 40)
        #expect(p.text == "Review in 40 seconds...")
        #expect(p.audio == .none)
        #expect(p.flash == .none)
        #expect(p.focusedMeetingID == "second")
        // Still silent and not flashing in the last seconds.
        let q = plan([first, second], 1800 - 2)
        #expect(q.flash == .none)
        #expect(q.audio == .none)
        #expect(q.text == "Review in 2 seconds...")
        #expect(plan([first, second], 1800 - 0.5).text == "Review in 1 second...")
        // Then its normal live text.
        #expect(plan([first, second], 1800).text == "Review is live!")
    }

    @Test func staysSilentEvenAfterOverlappingMeetingEnds() {
        // first ends 10 s into second's window: second must not start the tune then.
        let first = mtg("first", at: 0, minutes: 1) // ends at 60
        let second = mtg("second", at: 60 + lead - 10)
        let p = plan([first, second], 61)
        #expect(p.audio == .none)
        #expect(p.text?.hasSuffix("seconds...") == true)
    }

    @Test func windowBeginsWhileAnotherAlarmPlays() {
        let a = mtg("a", "Alpha", at: 0)
        let b = mtg("b", "Beta", at: 20) // b's window begins 20 s into a's alarm
        // During a's alarm: a owns sound and text, never interrupted.
        let p = plan([a, b], -10)
        #expect(p.audio == .play(offset: lead - 10, meetingID: "a"))
        #expect(p.text == "Alpha in 0:10")
        #expect(p.flash == .none)
        #expect(plan([a, b], -5).flash == .slow)
        #expect(plan([a, b], -5, playing: "a").audio == .keepPlaying(meetingID: "a"))
        // After a starts (a is also in progress): b is a silent countdown, then live.
        let q = plan([a, b], 5)
        #expect(q.text == "Beta in 15 seconds...")
        #expect(q.audio == .none)
        #expect(q.flash == .none)
        #expect(plan([a, b], 20).text == "Beta is live!")
    }

    @Test func earlierSoundNeverInterruptedEvenIfLaterWindowWouldBeLonger() {
        // Same start time: tie broken by id; exactly one tune.
        let a = mtg("a", at: 0)
        let b = mtg("b", at: 0)
        let p = plan([b, a], -30)
        #expect(p.audio.meetingID == "a")
        #expect(p.text == "a in 0:30")
    }

    @Test func backToBackChainOnlyFirstPlays() {
        // Three meetings 30 s apart: only the first owns the tune.
        let ms = [mtg("a", at: 0), mtg("b", at: 30), mtg("c", at: 60)]
        #expect(AlarmPlanner.soundOwners(ms, lead: lead) == ["a"])
        #expect(plan(ms, -1).audio.meetingID == "a")
        #expect(plan(ms, 10).audio == .none)
        #expect(plan(ms, 10).text == "b in 20 seconds...")
        #expect(plan(ms, 40).text == "c in 20 seconds...")
    }

    @Test func meetingAfterGapPlaysNormally() {
        // a ends at 30 min; b starts at 60 min: b's window begins with nothing in progress.
        let a = mtg("a", at: 0, minutes: 30)
        let b = mtg("b", "Beta", at: 3600)
        let p = plan([a, b], 3600 - 10)
        #expect(p.audio == .play(offset: lead - 10, meetingID: "b"))
        #expect(p.text == "Beta in 0:10")
    }

    @Test func nonQualifyingInProgressMeetingDoesNotSuppress() {
        let busy = mtg("busy", at: 0, minutes: 60, link: nil) // no link
        let b = mtg("b", at: 1800)
        #expect(plan([busy, b], 1800 - 10).audio == .play(offset: lead - 10, meetingID: "b"))
    }

    @Test func countdownWakesEachSecond() {
        let first = mtg("first", at: 0, minutes: 30)
        let second = mtg("second", at: 1800)
        #expect(plan([first, second], 1800 - 40.4).nextWakeDate == at(1800 - 40))
    }
}

@Suite struct TitleTests {
    @Test func shortTitleUnchanged() {
        #expect(AlarmPlanner.displayTitle("Standup") == "Standup")
        #expect(AlarmPlanner.displayTitle("  Standup \n") == "Standup")
    }

    @Test func longTitleTruncatedWithEllipsis() {
        let long = "Quarterly business review with the extended leadership team"
        let shown = AlarmPlanner.displayTitle(long)
        #expect(shown.count <= AlarmPlanner.maxTitleLength)
        #expect(shown.hasSuffix("…"))
        #expect(long.hasPrefix(String(shown.dropLast())))
        let p = plan([mtg("q", long, at: 0)], -16)
        #expect(p.text == "\(shown) in 0:16")
    }

    @Test func exactlyMaxLengthNotTruncated() {
        let title = String(repeating: "x", count: AlarmPlanner.maxTitleLength)
        #expect(AlarmPlanner.displayTitle(title) == title)
    }

    @Test func emptyTitleFallsBack() {
        #expect(AlarmPlanner.displayTitle("   ") == AlarmPlanner.untitledTitle)
    }

    @Test func emojiAreNotSplit() {
        let title = String(repeating: "👩‍👩‍👧", count: 40)
        let shown = AlarmPlanner.displayTitle(title)
        #expect(shown.count == AlarmPlanner.maxTitleLength)
    }
}

@Suite struct DeterminismTests {
    @Test func inputOrderDoesNotMatter() {
        let ms = [mtg("a", at: 0), mtg("b", at: 20), mtg("c", at: 3600)]
        for t in stride(from: -200.0, through: 3700, by: 7.3) {
            #expect(plan(ms, t) == plan(ms.reversed(), t))
        }
    }

    @Test func formatting() {
        #expect(AlarmPlanner.formatMinutesSeconds(0) == "0:00")
        #expect(AlarmPlanner.formatMinutesSeconds(16) == "0:16")
        #expect(AlarmPlanner.formatMinutesSeconds(96) == "1:36")
        #expect(AlarmPlanner.formatMinutesSeconds(600) == "10:00")
    }
}
