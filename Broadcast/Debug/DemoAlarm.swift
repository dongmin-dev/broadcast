#if DEBUG
import Foundation

/// Debug-only fake alarm: a 20-second countdown that drives the status item
/// and the audio exactly like a real alarm would, so the look can be checked
/// without a calendar.
@MainActor
final class DemoAlarm {
    static let title = "Standup"
    static let countdown: TimeInterval = 20
    static let slowFlashAt: TimeInterval = 8
    static let fastFlashAt: TimeInterval = 3
    /// How long "is live!" stays up before returning to idle.
    static let liveHold: TimeInterval = 5

    private let audio: AudioPlayer?
    private let update: @MainActor (StatusItemDisplay) -> Void
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    init(audio: AudioPlayer?, update: @escaping @MainActor (StatusItemDisplay) -> Void) {
        self.audio = audio
        self.update = update
    }

    /// What the status item shows with `remaining` seconds to the meeting.
    static func display(remaining: TimeInterval) -> StatusItemDisplay {
        if remaining <= 0 {
            return StatusItemDisplay(text: StatusItemDisplay.liveText(title: title), flash: .fast)
        }
        let flash: StatusItemDisplay.Flash =
            remaining <= fastFlashAt ? .fast : remaining <= slowFlashAt ? .slow : .none
        return StatusItemDisplay(
            text: StatusItemDisplay.countdownText(title: title, remaining: remaining),
            flash: flash
        )
    }

    func start() {
        stop()
        let start = Date.now
        let meeting = start.addingTimeInterval(Self.countdown)
        if let audio {
            // Start part-way in so the music ends as the meeting starts.
            audio.play(fromOffset: audio.duration - Self.countdown)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = meeting.timeIntervalSinceNow
                guard let self else { return }
                self.update(Self.display(remaining: remaining))
                if remaining <= -Self.liveHold { break }
                // Tick on whole seconds of the countdown.
                let fraction = remaining - remaining.rounded(.down)
                let wait = fraction > 0.01 ? fraction : 1
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, let self else { return }
            self.update(.idle)
            self.task = nil
        }
    }

    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        audio?.stop()
        update(.idle)
    }
}
#endif
