import Foundation

/// What the menu-bar status item should show. This is the only input to
/// `StatusItemController`; whatever drives alarms (the demo today, the
/// calendar scheduler later) just assigns a new value.
struct StatusItemDisplay: Equatable, Sendable {
    enum Flash: Equatable, Sendable {
        /// Normal menu-bar look, adapts to light and dark menu bars.
        case none
        /// Solid red background, white content blinking about once a second.
        case slow
        /// Solid red background, white content blinking several times a second.
        case fast
    }

    /// Text shown after the symbol. `nil` shows only the symbol.
    var text: String?
    var flash: Flash

    init(text: String? = nil, flash: Flash = .none) {
        self.text = text
        self.flash = flash
    }

    /// Symbol only, no flashing.
    static let idle = StatusItemDisplay()
}

extension StatusItemDisplay.Flash {
    /// Time for one half of a blink cycle (content visible, then hidden).
    /// `nil` when the content does not blink.
    var halfPeriod: Duration? {
        switch self {
        case .none: nil
        case .slow: .milliseconds(500)  // ~1 blink per second
        case .fast: .milliseconds(125)  // ~4 blinks per second
        }
    }
}

extension StatusItemDisplay {
    /// Formats a countdown such as "Standup in 0:16" or "Standup in 12:05".
    /// Negative values are treated as zero.
    static func countdownText(title: String, remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let minutes = total / 60
        let seconds = total % 60
        return "\(title) in \(minutes):\(String(format: "%02d", seconds))"
    }

    /// "Standup is live!"
    static func liveText(title: String) -> String {
        "\(title) is live!"
    }
}
