import AppKit

/// Owns the `NSStatusItem` and renders a `StatusItemDisplay` into it.
/// `MenuBarExtra` cannot draw a background behind its label, so this uses
/// AppKit directly.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var blinkTask: Task<Void, Never>?
    private var contentVisible = true

    /// Assigning a new value re-renders immediately and (re)starts blinking.
    var display: StatusItemDisplay = .idle {
        didSet {
            guard display != oldValue else { return }
            if display.flash != oldValue.flash { restartBlinking() }
            render()
        }
    }

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        render()
    }

    deinit {
        blinkTask?.cancel()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        button.image = StatusItemRenderer.image(for: display, contentVisible: contentVisible, height: height)
        button.title = ""
        button.setAccessibilityLabel(display.text ?? "Broadcast")
    }

    private func restartBlinking() {
        blinkTask?.cancel()
        blinkTask = nil
        contentVisible = true
        guard let halfPeriod = display.flash.halfPeriod else { return }
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: halfPeriod)
                guard !Task.isCancelled, let self else { return }
                self.contentVisible.toggle()
                self.render()
            }
        }
    }
}
