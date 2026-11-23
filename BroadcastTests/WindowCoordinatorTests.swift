import AppKit
import Testing
@testable import Broadcast

@MainActor
final class FakeApplication: ApplicationActivating {
    var policies: [NSApplication.ActivationPolicy] = []
    var activations = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) { policies.append(policy) }
    func activate() { activations += 1 }
}

@MainActor
@Suite("WindowCoordinator activation policy")
struct WindowCoordinatorTests {
    let app = FakeApplication()
    let coordinator: WindowCoordinator
    var created: [AppWindow] { createdBox.kinds }
    private let createdBox = CreatedBox()

    final class CreatedBox { var kinds: [AppWindow] = [] }

    init() {
        let box = createdBox
        coordinator = WindowCoordinator(application: app) { kind in
            box.kinds.append(kind)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: true
            )
            window.title = kind.title
            return window
        }
    }

    @Test func pureMapping() {
        #expect(WindowCoordinator.activationPolicy(forOpenWindows: []) == .accessory)
        #expect(WindowCoordinator.activationPolicy(forOpenWindows: [.settings]) == .regular)
        #expect(WindowCoordinator.activationPolicy(forOpenWindows: [.onboarding, .settings]) == .regular)
    }

    @Test func startsAsAccessoryWithoutTouchingTheApp() {
        #expect(coordinator.activationPolicy == .accessory)
        #expect(coordinator.openWindows.isEmpty)
        #expect(app.policies.isEmpty)
    }

    @Test func openingAWindowShowsDockIconAndActivates() {
        coordinator.open(.settings)
        #expect(app.policies == [.regular])
        #expect(app.activations == 1)
        #expect(coordinator.activationPolicy == .regular)
        #expect(coordinator.isOpen(.settings))
        coordinator.close(.settings)
    }

    @Test func closingTheLastWindowHidesDockIcon() {
        coordinator.open(.onboarding)
        coordinator.close(.onboarding)
        #expect(app.policies == [.regular, .accessory])
        #expect(coordinator.activationPolicy == .accessory)
        #expect(coordinator.openWindows.isEmpty)
    }

    @Test func dockIconStaysWhileAnotherWindowIsOpen() {
        coordinator.open(.onboarding)
        coordinator.open(.settings)
        #expect(app.policies == [.regular])
        #expect(app.activations == 2)

        coordinator.close(.onboarding)
        #expect(app.policies == [.regular])
        #expect(coordinator.openWindows == [.settings])

        coordinator.close(.settings)
        #expect(app.policies == [.regular, .accessory])
    }

    @Test func closingViaTheWindowItselfIsTracked() throws {
        coordinator.open(.settings)
        let window = try #require(coordinator.window(for: .settings))
        window.performClose(nil)
        #expect(!coordinator.isOpen(.settings))
        #expect(coordinator.activationPolicy == .accessory)
    }

    @Test func reopeningAnOpenWindowReusesItAndReactivates() {
        coordinator.open(.settings)
        let first = coordinator.window(for: .settings)
        coordinator.open(.settings)
        #expect(coordinator.window(for: .settings) === first)
        #expect(created == [.settings])
        #expect(app.policies == [.regular])
        #expect(app.activations == 2)
        coordinator.close(.settings)
    }

    @Test func aClosedWindowIsCreatedAgainOnNextOpen() {
        coordinator.open(.settings)
        coordinator.close(.settings)
        coordinator.open(.settings)
        #expect(created == [.settings, .settings])
        #expect(app.policies == [.regular, .accessory, .regular])
        coordinator.close(.settings)
    }

    @Test func closingAWindowThatIsNotOpenDoesNothing() {
        coordinator.close(.onboarding)
        #expect(app.policies.isEmpty)
    }

    @Test func defaultWindowsHavePlaceholderContent() {
        for kind in AppWindow.allCases {
            let window = WindowCoordinator.makeDefaultWindow(for: kind)
            #expect(window.title == kind.title)
            #expect(window.contentViewController != nil)
        }
    }
}
