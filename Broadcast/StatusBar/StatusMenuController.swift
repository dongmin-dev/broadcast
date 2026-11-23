import AppKit

/// Builds the menu shown when the status item is clicked and refreshes its
/// state each time it opens.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var isPlaying: @MainActor () -> Bool = { false }
        var stopSound: @MainActor () -> Void = {}
        var openSettings: @MainActor () -> Void = {}
        var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
        #if DEBUG
        var runDemoAlarm: @MainActor () -> Void = {}
        var showOnboarding: @MainActor () -> Void = {}
        #endif
    }

    static let alarmsPausedDefaultsKey = "alarmsPaused"

    let menu = NSMenu()
    private let actions: Actions
    private let defaults: UserDefaults

    /// Placeholder until the calendar is wired in.
    var nextMeetingText = "No upcoming meetings" {
        didSet { nextMeetingItem.title = nextMeetingText }
    }

    var alarmsPaused: Bool {
        get { defaults.bool(forKey: Self.alarmsPausedDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.alarmsPausedDefaultsKey) }
    }

    private let nextMeetingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var stopSoundItem = item("Stop Sound", #selector(stopSound))
    private lazy var pauseAlarmsItem = item("Pause Alarms", #selector(togglePauseAlarms))

    init(actions: Actions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.defaults = defaults
        super.init()
        buildMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        nextMeetingItem.title = nextMeetingText
        nextMeetingItem.isEnabled = false
        menu.addItem(nextMeetingItem)
        menu.addItem(.separator())
        menu.addItem(stopSoundItem)
        menu.addItem(pauseAlarmsItem)
        #if DEBUG
        menu.addItem(.separator())
        menu.addItem(item("Run Demo Alarm", #selector(runDemoAlarm)))
        menu.addItem(item("Show Onboarding", #selector(showOnboarding)))
        #endif
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Broadcast", #selector(quit), key: "q"))
        refresh()
    }

    func refresh() {
        stopSoundItem.isEnabled = actions.isPlaying()
        pauseAlarmsItem.state = alarmsPaused ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    @objc private func stopSound() { actions.stopSound() }
    @objc private func togglePauseAlarms() { alarmsPaused.toggle(); refresh() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { actions.quit() }
    #if DEBUG
    @objc private func runDemoAlarm() { actions.runDemoAlarm() }
    @objc private func showOnboarding() { actions.showOnboarding() }
    #endif
}
