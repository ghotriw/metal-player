import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Testing
import os

@testable import MetalPlayerCore

@Suite("PlayerEngine Tests", .serialized)
struct PlayerEngineTests {
    @Test("Engine initializes with expected defaults from configuration")
    @MainActor
    func testEngineInitializationDefaults() {
        let config = PlayerConfiguration(
            enableToneMapping: true,
            defaultRenderMode: .auto,
            targetNits: 250.0,
            sharpness: 0.7,
            initialVolume: 0.8
        )
        let engine = PlayerEngine(configuration: config)

        #expect(engine.isLoaded == false)
        #expect(engine.isPlaying == false)
        #expect(engine.currentTime == 0.0)
        #expect(engine.duration == 0.0)
        #expect(engine.volume == 0.8)
        #expect(engine.isMuted == false)
        #expect(engine.metalTargetNits == 250.0)
        #expect(engine.metalSharpness == 0.7)
        #expect(engine.isToneMappingPermitted == true)
        #expect(engine.renderMode == .auto)
        #expect(engine.displayLayer.videoGravity == .resizeAspect)
    }

    @Test("Active render mode dynamically computes based on display HDR and permission")
    @MainActor
    func testRenderModeResolution() {
        let engine = PlayerEngine()

        // Default: isHDRDisplay = true, auto -> .system
        engine.isHDRDisplay = true
        engine.isHDRContent = true
        engine.renderMode = .auto
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)

        // On SDR display with HDR content, auto -> .metalToneMap
        engine.isHDRDisplay = false
        #expect(engine.activeRenderMode == .metalToneMap)
        #expect(engine.isMetalLayerVisible == true)

        // On SDR display with SDR content, auto -> .system
        engine.isHDRContent = false
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)
        engine.isHDRContent = true

        // Explicit system mode
        engine.renderMode = .system
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)

        // Explicit metalToneMap mode
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .metalToneMap)
        #expect(engine.isMetalLayerVisible == true)

        // Tone mapping disabled forces .system
        engine.isToneMappingPermitted = false
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)
    }

    @Test("Volume and mute updates properly reflect on engine state")
    @MainActor
    func testVolumeAndMute() {
        let engine = PlayerEngine()

        engine.volume = 0.65
        #expect(engine.volume == 0.65)
        #expect(engine.isMuted == false)

        engine.isMuted = true
        #expect(engine.isMuted == true)

        engine.isMuted = false
        #expect(engine.isMuted == false)
    }

    @Test("Playback toggle and seek commands update internal state")
    @MainActor
    func testPlaybackControls() {
        let engine = PlayerEngine()

        // Toggle when unloaded does not play
        engine.togglePlayPause()
        #expect(engine.isPlaying == false)

        // Relative seek bounds
        engine.seek(to: 5.0)
        #expect(engine.currentTime == 0.0)  // duration is 0, clamped to [0, 0]

        engine.stepFrameForward()
        #expect(engine.currentTime == 0.0)

        engine.stepFrameBackward()
        #expect(engine.currentTime == 0.0)
    }

    @Test("Engine loads reference media file if present")
    @MainActor
    func testLoadReferenceMedia() {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        let engine = PlayerEngine()
        engine.load(path: referencePath)

        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0.0)
        #expect(engine.videoWidth > 0)
        #expect(engine.videoHeight > 0)
        #expect(engine.mediaTitle == URL(fileURLWithPath: referencePath).lastPathComponent)
        #expect(!engine.audioTracks.isEmpty)

        // Subtitles verification: synthetic uhdHDRSubtitles media contains 5 subrip tracks
        #expect(engine.subtitleTracks.count == 5)
        #expect(engine.selectedSubtitleTrackId == nil)

        // Select first track and verify track selection
        let firstSub = engine.subtitleTracks[0]
        #expect(firstSub.isForced == true)
        engine.selectSubtitleTrack(id: firstSub.id)
        #expect(engine.selectedSubtitleTrackId == firstSub.id)

        // Turn subtitles off
        engine.selectSubtitleTrack(id: nil)
        #expect(engine.selectedSubtitleTrackId == nil)
        #expect(engine.currentSubtitleText == nil)

        // Play and pause
        engine.play()
        #expect(engine.isPlaying == true)

        engine.pause()
        #expect(engine.isPlaying == false)

        // Seek
        engine.seek(to: 2.0)
        #expect(engine.currentTime == 2.0)

        engine.seekRelative(by: 1.0)
        #expect(engine.currentTime == 3.0)
        engine.stop()
    }

    @Test("Engine handles unavailable network URL gracefully with loadError and not loading")
    @MainActor
    func testLoadAsyncNetworkError() async {
        let engine = PlayerEngine()
        // Invalid port / non-existent local server that will fail or reject instantly
        await engine.loadAsync(path: "http://127.0.0.1:65534/nonexistent.mkv")

        #expect(engine.isLoaded == false)
        #expect(engine.isLoading == false)
        #expect(engine.loadError != nil)
    }

    @Test("Engine notifies playbackState changes and time updates")
    @MainActor
    func testPlaybackStateTransitions() async {
        let engine = PlayerEngine()
        #expect(engine.playbackState == .idle)

        var statesReceived: [PlaybackState] = []
        engine.onPlaybackStateChanged = { state in
            statesReceived.append(state)
        }

        // Test network error transition
        await engine.loadAsync(path: "http://127.0.0.1:65534/nonexistent.mkv")
        #expect(statesReceived.contains(.loading))
        if case .failed = engine.playbackState {
            // Success: state is failed
        } else {
            Issue.record("Expected playbackState to be .failed, but got \(engine.playbackState)")
        }

        // Stop resets to idle
        engine.stop()
        #expect(engine.playbackState == .idle)

        // Stopping active playback directly transitions to .idle without .paused
        engine.playbackState = .playing
        statesReceived.removeAll()
        engine.stop()
        #expect(engine.playbackState == .idle)
        #expect(statesReceived == [.idle])
    }

    @Test("Engine cancellation resets to idle instead of failed")
    @MainActor
    func testLoadCancellationResetsToIdle() async {
        let engine = PlayerEngine()
        let loadTask = Task { @MainActor in
            await engine.loadAsync(path: "http://127.0.0.1:65534/slow.mkv")
        }
        // Cancel immediately
        loadTask.cancel()
        await loadTask.value

        #expect(engine.playbackState == .idle)
        #expect(engine.loadError == nil)
    }

    @Test("Engine play restarts from start when in completed state")
    @MainActor
    func testPlayRestartsWhenCompleted() {
        guard let referencePath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        let engine = PlayerEngine()
        engine.load(path: referencePath)
        #expect(engine.isLoaded == true)

        engine.seek(to: 5.0)
        #expect(engine.currentTime == 5.0)

        engine.playbackState = .completed
        engine.play()  // should seek to 0.0
        #expect(engine.currentTime == 0.0)
        engine.stop()
    }

    @Test("MediaDemuxer.isNetworkURL correctly detects schemes case-insensitively")
    func testIsNetworkURL() {
        #expect(MediaDemuxer.isNetworkURL("http://example.com/video.mp4") == true)
        #expect(MediaDemuxer.isNetworkURL("HTTP://EXAMPLE.COM/VIDEO.MP4") == true)
        #expect(MediaDemuxer.isNetworkURL("https://secure.stream.io/hls.m3u8") == true)
        #expect(MediaDemuxer.isNetworkURL("Https://Secure.stream.io") == true)
        #expect(MediaDemuxer.isNetworkURL("/Users/user/video.mkv") == false)
        #expect(MediaDemuxer.isNetworkURL("file:///path/to/movie.mov") == false)
    }

    @Test("PlayerEngine.resolveTitle correctly prioritizes explicit title over URL and path")
    func testResolveTitle() {
        // 1. Explicit title always takes precedence
        #expect(PlayerEngine.resolveTitle(from: "http://example.com/stream", explicitTitle: "My Film") == "My Film")
        #expect(PlayerEngine.resolveTitle(from: "/path/video.mkv", explicitTitle: "Custom Title") == "Custom Title")

        // 2. Network URL fallback to lastPathComponent or host
        #expect(PlayerEngine.resolveTitle(from: "http://media.server:8096/videos/stream.mkv") == "stream.mkv")
        #expect(PlayerEngine.resolveTitle(from: "http://media.server:8096/") == "media.server")

        // 3. Local file path fallback to filename
        #expect(PlayerEngine.resolveTitle(from: "/Users/alice/Movies/Inception.2010.mkv") == "Inception.2010.mkv")
    }

    @Test("PlayerEngine load updates mediaTitle and stop clears it")
    @MainActor
    func testEngineMediaTitleLifecycle() {
        let engine = PlayerEngine()
        #expect(engine.mediaTitle == "")

        // Load with explicit title
        engine.load(path: "http://127.0.0.1:65534/dummy", title: "Blade Runner")
        #expect(engine.mediaTitle == "Blade Runner")

        // Stop resets title
        engine.stop()
        #expect(engine.mediaTitle == "")

        // Load without explicit title uses path resolution
        engine.load(path: "/path/to/Interstellar.mp4")
        #expect(engine.mediaTitle == "Interstellar.mp4")
        engine.stop()
    }

    @Test("PlayerEngine correctly loads and handles audio-only files without video")
    @MainActor
    func testAudioOnlyPlayback() {
        guard let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC) else { return }
        guard FileManager.default.fileExists(atPath: audioPath) else { return }

        let engine = PlayerEngine()
        engine.load(path: audioPath)

        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == false)
        #expect(engine.duration > 0.0)
        #expect(engine.videoWidth == 0)
        #expect(engine.videoHeight == 0)
        #expect(!engine.audioTracks.isEmpty)

        // Test playback control
        engine.play()
        #expect(engine.isPlaying == true)

        engine.pause()
        #expect(engine.isPlaying == false)

        // Test seek
        engine.seek(to: 5.0)
        #expect(engine.currentTime == 5.0)

        engine.seekRelative(by: 2.0)
        #expect(engine.currentTime == 7.0)

        engine.stop()
        #expect(engine.isLoaded == false)
        #expect(engine.playbackState == .idle)
    }

    @Test("Switching from video to audio-only file clears video state")
    @MainActor
    func testVideoToAudioSwitchClearsVideoState() {
        guard let referenceVideoPath = SyntheticTestMediaFactory.ensureMedia(preset: .uhdHDRSubtitles) else { return }
        guard let audioPath = SyntheticTestMediaFactory.ensureMedia(preset: .audioOnlyFLAC) else { return }
        guard
            FileManager.default.fileExists(atPath: audioPath)
        else { return }

        let engine = PlayerEngine()
        // 1. Load video
        engine.load(path: referenceVideoPath)
        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == true)
        #expect(engine.videoWidth > 0)

        // 2. Load audio directly (simulates Command + O open audio file after video)
        engine.load(path: audioPath)
        #expect(engine.isLoaded == true)
        #expect(engine.hasVideo == false)
        #expect(engine.videoWidth == 0)
        #expect(engine.videoHeight == 0)

        engine.stop()
        #expect(engine.isLoaded == false)
    }
}
