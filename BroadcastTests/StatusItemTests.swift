import AppKit
import Testing
@testable import Broadcast

@MainActor
@Suite("Status item display and rendering")
struct StatusItemTests {
    @Test func countdownFormatting() {
        #expect(StatusItemDisplay.countdownText(title: "Standup", remaining: 16) == "Standup in 0:16")
        #expect(StatusItemDisplay.countdownText(title: "Standup", remaining: 15.2) == "Standup in 0:16")
        #expect(StatusItemDisplay.countdownText(title: "Standup", remaining: 725) == "Standup in 12:05")
        #expect(StatusItemDisplay.countdownText(title: "Standup", remaining: -3) == "Standup in 0:00")
        #expect(StatusItemDisplay.liveText(title: "Standup") == "Standup is live!")
    }

    @Test func fastBlinksFasterThanSlow() throws {
        #expect(StatusItemDisplay.Flash.none.halfPeriod == nil)
        let slow = try #require(StatusItemDisplay.Flash.slow.halfPeriod)
        let fast = try #require(StatusItemDisplay.Flash.fast.halfPeriod)
        #expect(slow == .milliseconds(500))
        #expect(fast < slow / 2)
    }

    @Test func symbolOnlyIsNarrowerThanSymbolWithText() {
        let plain = StatusItemRenderer.size(for: nil, height: 24)
        let text = StatusItemRenderer.size(for: "Standup in 0:16", height: 24)
        #expect(plain.width < text.width)
        #expect(plain.height == 24)
    }

    @Test func countdownWidthDoesNotJitter() {
        let widths = (0...59).map {
            StatusItemRenderer.size(for: StatusItemDisplay.countdownText(title: "Standup", remaining: TimeInterval($0)), height: 24).width
        }
        #expect(Set(widths).count == 1)
    }

    @Test func templateOnlyWhenNotFlashing() {
        let normal = StatusItemRenderer.image(for: StatusItemDisplay(text: "Standup in 0:16"), height: 24)
        let flashing = StatusItemRenderer.image(for: StatusItemDisplay(text: "Standup in 0:08", flash: .slow), height: 24)
        let hidden = StatusItemRenderer.image(
            for: StatusItemDisplay(text: "Standup in 0:08", flash: .slow), contentVisible: false, height: 24)
        #expect(normal.isTemplate)
        #expect(!flashing.isTemplate)
        #expect(flashing.size == hidden.size)
        #expect(StatusItemRenderer.symbolImage(color: .white) != nil)
    }

    #if DEBUG
    @Test func demoAlarmPhases() {
        #expect(DemoAlarm.display(remaining: 20) == StatusItemDisplay(text: "Standup in 0:20", flash: .none))
        #expect(DemoAlarm.display(remaining: 9) == StatusItemDisplay(text: "Standup in 0:09", flash: .none))
        #expect(DemoAlarm.display(remaining: 8) == StatusItemDisplay(text: "Standup in 0:08", flash: .slow))
        #expect(DemoAlarm.display(remaining: 4) == StatusItemDisplay(text: "Standup in 0:04", flash: .slow))
        #expect(DemoAlarm.display(remaining: 3) == StatusItemDisplay(text: "Standup in 0:03", flash: .fast))
        #expect(DemoAlarm.display(remaining: 0) == StatusItemDisplay(text: "Standup is live!", flash: .fast))
        #expect(DemoAlarm.display(remaining: -2).text == "Standup is live!")
    }
    #endif

    @Test func menuStopSoundEnabledOnlyWhilePlaying() throws {
        var playing = false
        var actions = StatusMenuController.Actions()
        actions.isPlaying = { playing }
        let defaults = try #require(UserDefaults(suiteName: "BroadcastTests.menu"))
        defaults.removePersistentDomain(forName: "BroadcastTests.menu")
        let controller = StatusMenuController(actions: actions, defaults: defaults)
        let titles = controller.menu.items.map(\.title)
        #expect(titles.contains("Stop Sound"))
        #expect(titles.contains("Pause Alarms"))
        #expect(titles.contains("Settings…"))
        #expect(titles.contains("Quit Broadcast"))
        #expect(titles.first == "No upcoming meetings")

        let stop = try #require(controller.menu.items.first { $0.title == "Stop Sound" })
        #expect(!stop.isEnabled)
        playing = true
        controller.refresh()
        #expect(stop.isEnabled)

        let pause = try #require(controller.menu.items.first { $0.title == "Pause Alarms" })
        #expect(pause.state == .off)
        controller.alarmsPaused = true
        controller.refresh()
        #expect(pause.state == .on)
    }
}
