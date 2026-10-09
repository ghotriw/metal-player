import Foundation
import MediaPlayer
import MetalPlayerCore
import MetalPlayerKit
import Testing

#if canImport(NowPlaying)
    import NowPlaying
#endif

@Suite("NowPlaying Controller Tests")
struct NowPlayingTests {
    @Test("LegacyMediaPlayerController sets nowPlayingInfo and playbackState accurately")
    @MainActor
    func testLegacyMediaPlayerStateAndMetadata() async throws {
        let engine = PlayerEngine()
        let legacy = LegacyMediaPlayerController(engine: engine)
        let center = MPNowPlayingInfoCenter.default()

        // 1. Initial playback update
        legacy.update(title: "Inception", currentTime: 15.0, duration: 8880.0, isPlaying: true)

        #expect(center.playbackState == .playing)
        let info = try #require(center.nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Inception")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 8880.0)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 15.0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)

        // 2. Pause update
        legacy.update(title: "Inception", currentTime: 18.0, duration: 8880.0, isPlaying: false)
        #expect(center.playbackState == .paused)
        let pausedInfo = try #require(center.nowPlayingInfo)
        #expect(pausedInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)

        // 3. Normal 1s progression does not trigger premature updates due to extrapolation
        // (calling update with small linear delta should not overwrite unless heartbeat or seek)
        legacy.update(title: "Inception", currentTime: 18.5, duration: 8880.0, isPlaying: false)
        let unchangedInfo = try #require(center.nowPlayingInfo)
        #expect(unchangedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 18.0)

        // 4. Seek jump (delta > 1.5s) immediately triggers update
        legacy.update(title: "Inception", currentTime: 120.0, duration: 8880.0, isPlaying: false)
        let seekedInfo = try #require(center.nowPlayingInfo)
        #expect(seekedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 120.0)

        // 5. Clear resets everything
        legacy.clear()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("LegacyMediaPlayerController respects isKeyWindow focus state")
    @MainActor
    func testLegacyCommandCenterKeyWindowToggling() async throws {
        let engine = PlayerEngine()
        let legacy = LegacyMediaPlayerController(engine: engine)
        let remote = MPRemoteCommandCenter.shared()

        legacy.isKeyWindow = true
        #expect(remote.togglePlayPauseCommand.isEnabled == true)
        #expect(remote.playCommand.isEnabled == true)
        #expect(remote.pauseCommand.isEnabled == true)

        legacy.isKeyWindow = false
        #expect(remote.togglePlayPauseCommand.isEnabled == false)
        #expect(remote.playCommand.isEnabled == false)
        #expect(remote.pauseCommand.isEnabled == false)

        legacy.clear()
    }

    #if canImport(NowPlaying)
        @Test("ModernNowPlayingModel creates valid snapshot and metadata")
        @available(macOS 27.0, *)
        @MainActor
        func testModernNowPlayingModel() async throws {
            let model = ModernNowPlayingModel(id: "test-model")
            model.title = "Interstellar"
            model.duration = 10140.0
            model.currentTime = 42.0
            model.isPlaying = true

            let content = try #require(model.content as? MovieContent)
            #expect(content.title == "Interstellar")

            let snapshot = try #require(model.playbackSnapshot)
            _ = snapshot

            // Pause state
            model.isPlaying = false
            let pausedSnapshot = try #require(model.playbackSnapshot)
            _ = pausedSnapshot
        }

        @Test("ModernNowPlayingController lifecycle and clear")
        @available(macOS 27.0, *)
        @MainActor
        func testModernNowPlayingControllerLifecycle() async throws {
            let engine = PlayerEngine()
            let controller = ModernNowPlayingController(engine: engine)

            controller.update(title: "Dune", currentTime: 0.0, duration: 9300.0, isPlaying: true)
            #expect(controller.model.title == "Dune")
            #expect(controller.model.isPlaying == true)
            #expect(controller.model.currentTime == 0.0)

            controller.clear()
            #expect(controller.model.title == "")
            #expect(controller.model.isPlaying == false)
        }
    #endif

    @Test("NowPlayingControllerFactory returns an instance without error")
    @MainActor
    func testFactoryCreation() async throws {
        let engine = PlayerEngine()
        let controller = NowPlayingControllerFactory.makeController(engine: engine)
        #expect(controller.isKeyWindow == true)
        controller.update(title: "Factory Video", currentTime: 0, duration: 100, isPlaying: true)
        controller.clear()
    }
}
