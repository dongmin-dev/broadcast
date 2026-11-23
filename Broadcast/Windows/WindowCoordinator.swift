import AppKit
import SwiftUI

/// The app's windows. The app is menu-bar only; these are the only windows.
enum AppWindow: String, CaseIterable, Sendable {
    case onboarding
    case settings

    var title: String {
        switch self {
        case .onboarding: "Welcome to Broadcast"
        case .settings: "Broadcast Settings"
        }
    }
}

/// The part of `NSApplication` the coordinator needs; swapped out in tests.
@MainActor
protocol ApplicationActivating: AnyObject {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

@MainActor
final class SystemApplicationActivator: ApplicationActivating {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApplication.shared.setActivationPolicy(policy)
    }

    func activate() {
        NSApplication.shared.activate()
    }
}

/// Opens and tracks the Onboarding and Settings windows.
///
/// With no window open the app is an accessory (menu bar only, no Dock icon).
/// While any window is open it is a regular app (Dock icon, app menu) and is
/// brought to the front; when the last window closes it goes back to accessory.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    typealias WindowFactory = @MainActor (AppWindow) -> NSWindow

    private let application: ApplicationActivating
    private let makeWindow: WindowFactory
    private var windows: [AppWindow: NSWindow] = [:]

    /// The policy most recently applied to the application.
    private(set) var activationPolicy: NSApplication.ActivationPolicy = .accessory

    var openWindows: Set<AppWindow> { Set(windows.keys) }

    func isOpen(_ kind: AppWindow) -> Bool { windows[kind] != nil }

    /// The policy that should apply for a given set of open windows.
    static func activationPolicy(forOpenWindows open: Set<AppWindow>) -> NSApplication.ActivationPolicy {
        open.isEmpty ? .accessory : .regular
    }

    init(
        application: ApplicationActivating = SystemApplicationActivator(),
        makeWindow: @escaping WindowFactory = WindowCoordinator.makeDefaultWindow
    ) {
        self.application = application
        self.makeWindow = makeWindow
        super.init()
    }

    /// Shows the window (creating it if needed), shows the Dock icon and
    /// brings the app to the front.
    func open(_ kind: AppWindow) {
        let window: NSWindow
        if let existing = windows[kind] {
            window = existing
        } else {
            window = makeWindow(kind)
            window.isReleasedWhenClosed = false
            window.delegate = self
            windows[kind] = window
            window.center()
        }
        updateActivationPolicy()
        application.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window if it is open.
    func close(_ kind: AppWindow) {
        windows[kind]?.close()
    }

    func window(for kind: AppWindow) -> NSWindow? { windows[kind] }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === closing })?.key
        else { return }
        closing.delegate = nil
        windows[kind] = nil
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let policy = Self.activationPolicy(forOpenWindows: openWindows)
        guard policy != activationPolicy else { return }
        activationPolicy = policy
        application.setActivationPolicy(policy)
    }

    // MARK: Default windows

    static func makeDefaultWindow(for kind: AppWindow) -> NSWindow {
        let content: AnyView = switch kind {
        case .onboarding: AnyView(OnboardingView())
        case .settings: AnyView(SettingsView())
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = kind.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.identifier = NSUserInterfaceItemIdentifier("broadcast.\(kind.rawValue)")
        window.setFrameAutosaveName("broadcast.\(kind.rawValue)")
        return window
    }
}
