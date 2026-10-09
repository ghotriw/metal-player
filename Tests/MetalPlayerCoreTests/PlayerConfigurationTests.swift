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
        let engine = PlayerEngine(configuration: config)

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

    @Test("CLI arguments correctly parse HTTP headers and network URL")
    func testParseHTTPHeadersAndURL() {
        let args = [
            "MetalPlayer",
            "--header=X-Api-Key: test-api-key-12345",
            "--header",
            "Authorization: Bearer token-xyz",
            "https://stream.example.com/videos/123/stream.mkv",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(mediaPath == "https://stream.example.com/videos/123/stream.mkv")
        #expect(config.httpHeaders["X-Api-Key"] == "test-api-key-12345")
        #expect(config.httpHeaders["Authorization"] == "Bearer token-xyz")
    }

    @Test("CLI arguments correctly parse start-time and resume flags")
    func testParseStartTimeAndResumeFlags() {
        let args = [
            "MetalPlayer",
            "--start-time=124.5",
            "--no-resume",
            "movie.mkv",
        ]
        let (config, mediaPath) = PlayerConfiguration.parse(arguments: args)

        #expect(mediaPath == "movie.mkv")
        #expect(config.startTime == 124.5)
        #expect(config.resumePlayback == false)
    }

    @Test("CLI arguments correctly parse subtitle font name")
    func testParseSubtitleFontFlag() {
        let args = ["MetalPlayer", "--subtitle-font=Helvetica Neue", "movie.mkv"]
        let (config, _) = PlayerConfiguration.parse(arguments: args)
        #expect(config.subtitleFontName == "Helvetica Neue")
    }

    @Test("UserDefaults roundtrip preserves subtitle font name")
    func testUserDefaultsSubtitleFont() {
        let defaults = UserDefaults(suiteName: "test.subtitle.font")!
        defaults.removePersistentDomain(forName: "test.subtitle.font")
        var config = PlayerConfiguration()
        config.subtitleFontName = "Avenir Next"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontName == "Avenir Next")
    }

    @Test("CLI arguments correctly parse subtitle font weight")
    func testParseSubtitleWeightFlag() {
        let args = ["MetalPlayer", "--subtitle-weight=bold", "movie.mkv"]
        let (config, _) = PlayerConfiguration.parse(arguments: args)
        #expect(config.subtitleFontWeight == "bold")
    }

    @Test("UserDefaults roundtrip preserves subtitle font weight")
    func testUserDefaultsSubtitleWeight() {
        let defaults = UserDefaults(suiteName: "test.subtitle.weight")!
        defaults.removePersistentDomain(forName: "test.subtitle.weight")
        var config = PlayerConfiguration()
        config.subtitleFontWeight = "Heavy"
        config.saveToUserDefaults(userDefaults: defaults)

        let loaded = PlayerConfiguration.loadFromUserDefaults(userDefaults: defaults)
        #expect(loaded.subtitleFontWeight == "Heavy")
    }
}
