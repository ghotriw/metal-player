import Foundation
import Testing

@testable import MetalPlayerCore

@Suite("PlayerConfiguration & Launch Arguments Tests")
struct PlayerConfigurationTests {

    @Test("Default configuration enables tone mapping and auto render mode")
    func testDefaultConfiguration() {
        let config = PlayerConfiguration()
        #expect(config.enableToneMapping == true)
        #expect(config.defaultRenderMode == .auto)
        #expect(config.targetNits == 203.0)
        #expect(config.sharpness == 0.5)
        #expect(config.initialVolume == 1.0)
    }

    @Test("CLI arguments correctly parse tone mapping disable flag")
    func testParseDisableToneMapping() {
        let args = ["MetalPlayer", "--disable-tone-mapping", "/path/to/movie.mkv"]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(config.enableToneMapping == false)
        #expect(mediaPath == "/path/to/movie.mkv")
    }

    @Test("CLI arguments parse render mode, target nits, sharpness, and volume")
    func testParseCustomFlags() {
        let args = [
            "MetalPlayer",
            "--render-mode=system",
            "--target-nits=300",
            "--sharpness=0.8",
            "--volume=0.4",
            "video.mp4",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(config.defaultRenderMode == .system)
        #expect(config.targetNits == 300.0)
        #expect(config.sharpness == 0.8)
        #expect(config.initialVolume == 0.4)
        #expect(mediaPath == "video.mp4")
    }

    @Test("Engine respects isToneMappingPermitted=false even on SDR display")
    @MainActor
    func testEngineToneMappingDisabled() {
        let config = PlayerConfiguration(enableToneMapping: false, defaultRenderMode: .auto)
        let engine = NativePlayerEngine(configuration: config)

        engine.isHDRDisplay = false  // Normally triggers .metalToneMap in auto mode
        #expect(engine.isToneMappingPermitted == false)
        #expect(engine.activeRenderMode == .system)

        // Attempting to manually switch to metalToneMap when prohibited remains system
        engine.renderMode = .metalToneMap
        #expect(engine.activeRenderMode == .system)

        // Re-enabling tone mapping dynamically restores metalToneMap
        engine.isToneMappingPermitted = true
        #expect(engine.activeRenderMode == .metalToneMap)
    }
}
