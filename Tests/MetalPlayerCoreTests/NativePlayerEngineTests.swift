import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Testing

@testable import MetalPlayerCore

@Suite("NativePlayerEngine Tests")
struct NativePlayerEngineTests {
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
        let engine = NativePlayerEngine(configuration: config)

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
        let engine = NativePlayerEngine()

        // Default: isHDRDisplay = true, auto -> .system
        engine.isHDRDisplay = true
        engine.renderMode = .auto
        #expect(engine.activeRenderMode == .system)
        #expect(engine.isMetalLayerVisible == false)

        // On SDR display, auto -> .metalToneMap
        engine.isHDRDisplay = false
        #expect(engine.activeRenderMode == .metalToneMap)
        #expect(engine.isMetalLayerVisible == true)

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
        let engine = NativePlayerEngine()

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
        let engine = NativePlayerEngine()

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
        let referencePath = "/Users/ghotriw/w_hdm_full.mkv"
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return
        }

        let engine = NativePlayerEngine()
        engine.load(path: referencePath)

        #expect(engine.isLoaded == true)
        #expect(engine.duration > 0.0)
        #expect(engine.videoWidth > 0)
        #expect(engine.videoHeight > 0)
        #expect(engine.mediaTitle == "w_hdm_full.mkv")
        #expect(!engine.audioTracks.isEmpty)

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
    }
}
