import Foundation
import Testing
@testable import Broadcast

@Suite("AudioPlayer offset handling")
struct AudioPlayerOffsetTests {
    @Test(arguments: [
        (0.0, 95.04, 0.0 as Double?),
        (10.5, 95.04, 10.5),
        (-5, 95.04, 0),
        (95.0, 95.04, 95.0),
        (95.04, 95.04, nil),
        (200, 95.04, nil),
        (.infinity, 95.04, nil),
        (.nan, 95.04, nil),
        (1, 0, nil),
    ])
    func startTime(offset: Double, duration: Double, expected: Double?) {
        #expect(AudioPlayer.startTime(forOffset: offset, duration: duration) == expected)
    }
}

@MainActor
@Suite("AudioPlayer with bundled sound", .serialized)
struct AudioPlayerBundledTests {
    let player: AudioPlayer

    init() throws {
        player = try AudioPlayer(bundle: Bundle(for: AppDelegate.self))
        player.volume = 0
    }

    @Test func durationIsReadFromTheFile() {
        #expect(player.duration > 94.9)
        #expect(player.duration < 95.2)
    }

    @Test func playFromOffsetStartsThereAndStopResets() {
        #expect(player.play(fromOffset: player.duration - 20))
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - (player.duration - 20)) < 0.5)

        player.stop()
        #expect(!player.isPlaying)
        #expect(player.currentTime == 0)
    }

    @Test func playPastTheEndDoesNothing() {
        #expect(!player.play(fromOffset: player.duration))
        #expect(!player.isPlaying)
    }

    @Test func outputDeviceChangeKeepsPlayingFromSamePosition() {
        player.play(fromOffset: 50)
        player.handleOutputDeviceChange()
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - 50) < 0.5)
        player.stop()

        player.handleOutputDeviceChange()
        #expect(!player.isPlaying)
    }

    @Test func missingResourceThrows() {
        #expect(throws: AudioPlayer.LoadError.self) {
            _ = try AudioPlayer(bundle: Bundle(for: FakeApplication.self))
        }
    }
}
