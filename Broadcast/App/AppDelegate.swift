import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "Broadcast", category: "App")

    let windows = WindowCoordinator()
    private(set) var audio: AudioPlayer?
    private(set) var statusItem: StatusItemController?
    private var menuController: StatusMenuController?
    #if DEBUG
    private var demo: DemoAlarm?
    #endif

    /// True when the app is only hosting unit tests; skip UI side effects.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = MainMenu.make()
        guard !Self.isRunningTests else { return }

        do {
            audio = try AudioPlayer()
        } catch {
            log.error("Could not load bundled sound: \(error.localizedDescription)")
        }

        var actions = StatusMenuController.Actions()
        actions.isPlaying = { [weak self] in self?.audio?.isPlaying ?? false }
        actions.stopSound = { [weak self] in self?.stopSound() }
        actions.openSettings = { [weak self] in self?.windows.open(.settings) }
        #if DEBUG
        actions.runDemoAlarm = { [weak self] in self?.demo?.start() }
        actions.showOnboarding = { [weak self] in self?.windows.open(.onboarding) }
        #endif

        let menuController = StatusMenuController(actions: actions)
        let statusItem = StatusItemController(menu: menuController.menu)
        self.menuController = menuController
        self.statusItem = statusItem

        #if DEBUG
        demo = DemoAlarm(audio: audio) { [weak statusItem] display in
            statusItem?.display = display
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.open(.settings) }
        return true
    }

    private func stopSound() {
        #if DEBUG
        if demo?.isRunning == true { demo?.stop(); return }
        #endif
        audio?.stop()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        windows.open(.settings)
    }
}
