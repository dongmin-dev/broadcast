import AVFoundation
import CoreAudio

/// Plays the bundled theme tune.
///
/// `duration` is read from the audio file and is the alarm lead time: an
/// alarm for a meeting starting in `t` seconds calls `play(fromOffset:
/// duration - t)` so the music ends exactly when the meeting starts.
///
/// When the system's default output device changes (headphones plugged in,
/// AirPods connect, …) playback is moved to the new device and continues from
/// the same position.
@MainActor
final class AudioPlayer {
    enum LoadError: Error {
        case resourceMissing(String)
    }

    static let bundledResourceName = "sound"
    static let bundledResourceExtension = "mp3"

    let url: URL
    /// Length of the sound in seconds, read from the file.
    let duration: TimeInterval

    private var player: AVAudioPlayer
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Playback volume, 0...1. Kept across output-device changes.
    var volume: Float = 1 {
        didSet { player.volume = volume }
    }

    var isPlaying: Bool { player.isPlaying }

    /// Current position in seconds from the start of the sound.
    var currentTime: TimeInterval { player.currentTime }

    init(url: URL) throws {
        self.url = url
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        self.player = player
        self.duration = player.duration
        startObservingOutputDevice()
    }

    /// Loads `sound.mp3` from `bundle` (the app bundle by default).
    convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(
            forResource: Self.bundledResourceName,
            withExtension: Self.bundledResourceExtension
        ) else {
            throw LoadError.resourceMissing("\(Self.bundledResourceName).\(Self.bundledResourceExtension)")
        }
        try self.init(url: url)
    }

    isolated deinit {
        stopObservingOutputDevice()
        player.stop()
    }

    /// Where playback should start for a requested offset, or `nil` when
    /// nothing would be left to play. Negative offsets start at the beginning.
    nonisolated static func startTime(forOffset offset: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard offset.isFinite, duration > 0 else { return nil }
        let clamped = max(0, offset)
        return clamped < duration ? clamped : nil
    }

    /// Starts playing `offset` seconds into the sound (restarting if already
    /// playing). Returns `false` and does nothing when `offset` is at or past
    /// the end of the sound.
    @discardableResult
    func play(fromOffset offset: TimeInterval = 0) -> Bool {
        guard let start = Self.startTime(forOffset: offset, duration: duration) else { return false }
        player.stop()
        player.currentTime = start
        player.volume = volume
        return player.play()
    }

    func stop() {
        player.stop()
        player.currentTime = 0
    }

    // MARK: - Output device changes

    /// Rebuilds the underlying player so it renders to the current default
    /// output device, resuming from the same position if it was playing.
    func handleOutputDeviceChange() {
        let wasPlaying = player.isPlaying
        let position = player.currentTime
        player.stop()
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else { return }
        fresh.volume = volume
        fresh.prepareToPlay()
        player = fresh
        if wasPlaying {
            player.currentTime = position
            player.play()
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func startObservingOutputDevice() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleOutputDeviceChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if status == noErr { deviceListener = listener }
    }

    private func stopObservingOutputDevice() {
        guard let listener = deviceListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        deviceListener = nil
    }
}
