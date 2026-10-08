import Foundation

/// Global configuration for playback behavior, rendering engines, and hardware options.
public struct PlayerConfiguration: Sendable, Equatable {
    /// Whether automatic tone mapping and custom Metal SDR rendering are permitted.
    /// When `false`, the player strictly utilizes Apple's native `AVSampleBufferDisplayLayer` pipeline
    /// and never engages custom Metal compute tone mapping.
    public var enableToneMapping: Bool

    /// Default render mode requested on startup.
    public var defaultRenderMode: RenderMode

    /// Target reference white level in nits for BT.2390 tone mapping (default 203.0).
    public var targetNits: Float

    /// Default sharpness factor for FidelityFX CAS (0.0 ... 1.0).
    public var sharpness: Float

    /// Default volume level (0.0 ... 1.0).
    public var initialVolume: Float

    /// Custom HTTP headers to pass when streaming over HTTP/HTTPS (e.g. for custom authentication tokens).
    public var httpHeaders: [String: String]

    /// Whether to automatically resume playback from previously saved position (default true).
    public var resumePlayback: Bool

    /// Minimum seconds played before a position is saved / resumed (default 15.0).
    public var resumeStartThreshold: Double

    /// Fraction of video duration after which it is considered completed (default 0.95).
    public var resumeEndThresholdRatio: Double

    /// Explicit start time in seconds requested on launch (if provided, overrides resume history).
    public var startTime: Double?

    public init(
        enableToneMapping: Bool = true,
        defaultRenderMode: RenderMode = .auto,
        targetNits: Float = 203.0,
        sharpness: Float = 0.5,
        initialVolume: Float = 1.0,
        httpHeaders: [String: String] = [:],
        resumePlayback: Bool = true,
        resumeStartThreshold: Double = 15.0,
        resumeEndThresholdRatio: Double = 0.95,
        startTime: Double? = nil
    ) {
        self.enableToneMapping = enableToneMapping
        self.defaultRenderMode = defaultRenderMode
        self.targetNits = targetNits
        self.sharpness = sharpness
        self.initialVolume = initialVolume
        self.httpHeaders = httpHeaders
        self.resumePlayback = resumePlayback
        self.resumeStartThreshold = resumeStartThreshold
        self.resumeEndThresholdRatio = resumeEndThresholdRatio
        self.startTime = startTime
    }

    public static let keyEnableToneMapping = "MetalPlayer.enableToneMapping"
    public static let keyTargetNits = "MetalPlayer.targetNits"
    public static let keySharpness = "MetalPlayer.sharpness"
    public static let keyResumePlayback = "MetalPlayer.resumePlayback"
    public static let keyResumeStartThreshold = "MetalPlayer.resumeStartThreshold"
    public static let keyResumeEndThresholdRatio = "MetalPlayer.resumeEndThresholdRatio"

    /// Loads configuration from UserDefaults, falling back to defaults if not set.
    public static func loadFromUserDefaults(userDefaults: UserDefaults = .standard) -> PlayerConfiguration {
        var config = PlayerConfiguration()
        if userDefaults.object(forKey: keyEnableToneMapping) != nil {
            config.enableToneMapping = userDefaults.bool(forKey: keyEnableToneMapping)
        }
        if let targetNits = userDefaults.object(forKey: keyTargetNits) as? NSNumber {
            config.targetNits = targetNits.floatValue
        }
        if let sharpness = userDefaults.object(forKey: keySharpness) as? NSNumber {
            config.sharpness = sharpness.floatValue
        }
        if userDefaults.object(forKey: keyResumePlayback) != nil {
            config.resumePlayback = userDefaults.bool(forKey: keyResumePlayback)
        }
        if let startThreshold = userDefaults.object(forKey: keyResumeStartThreshold) as? NSNumber {
            config.resumeStartThreshold = startThreshold.doubleValue
        }
        if let endThreshold = userDefaults.object(forKey: keyResumeEndThresholdRatio) as? NSNumber {
            config.resumeEndThresholdRatio = endThreshold.doubleValue
        }
        return config
    }

    /// Saves configuration properties to UserDefaults.
    public func saveToUserDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(enableToneMapping, forKey: Self.keyEnableToneMapping)
        userDefaults.set(targetNits, forKey: Self.keyTargetNits)
        userDefaults.set(sharpness, forKey: Self.keySharpness)
        userDefaults.set(resumePlayback, forKey: Self.keyResumePlayback)
        userDefaults.set(resumeStartThreshold, forKey: Self.keyResumeStartThreshold)
        userDefaults.set(resumeEndThresholdRatio, forKey: Self.keyResumeEndThresholdRatio)
    }

    /// Parses command-line arguments into a configuration structure and returns
    /// the configuration along with any remaining non-flag arguments (such as media paths).
    /// If `base` is supplied, command line flags will override values from `base`.
    public static func parse(
        arguments: [String] = CommandLine.arguments,
        base: PlayerConfiguration = PlayerConfiguration()
    ) -> (configuration: PlayerConfiguration, mediaPath: String?) {
        var config = base
        var mediaPath: String?

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]

            if arg == "--disable-tone-mapping" || arg == "--no-tone-mapping" {
                config.enableToneMapping = false
            } else if arg == "--enable-tone-mapping" {
                config.enableToneMapping = true
            } else if arg.starts(with: "--render-mode=") {
                let val = String(arg.dropFirst("--render-mode=".count)).lowercased()
                if val == "system" || val == "hdr" {
                    config.defaultRenderMode = .system
                } else if val == "metal" || val == "sdr" || val == "tonemap" {
                    config.defaultRenderMode = .metalToneMap
                } else {
                    config.defaultRenderMode = .auto
                }
            } else if arg.starts(with: "--target-nits=") {
                if let val = Float(arg.dropFirst("--target-nits=".count)) {
                    config.targetNits = val
                }
            } else if arg.starts(with: "--sharpness=") {
                if let val = Float(arg.dropFirst("--sharpness=".count)) {
                    config.sharpness = max(0.0, min(1.0, val))
                }
            } else if arg.starts(with: "--volume=") {
                if let val = Float(arg.dropFirst("--volume=".count)) {
                    config.initialVolume = max(0.0, min(1.0, val))
                }
            } else if arg.starts(with: "--start-time=") {
                if let val = Double(arg.dropFirst("--start-time=".count)) {
                    config.startTime = max(0.0, val)
                }
            } else if arg == "--start-time" && i + 1 < arguments.count {
                i += 1
                if let val = Double(arguments[i]) {
                    config.startTime = max(0.0, val)
                }
            } else if arg == "--no-resume" || arg == "--disable-resume" {
                config.resumePlayback = false
            } else if arg == "--resume" || arg == "--enable-resume" {
                config.resumePlayback = true
            } else if arg.starts(with: "--header=") {
                let headerStr = String(arg.dropFirst("--header=".count))
                if let colonIdx = headerStr.firstIndex(of: ":") {
                    let key = headerStr[..<colonIdx].trimmingCharacters(in: .whitespaces)
                    let val = headerStr[headerStr.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        config.httpHeaders[key] = val
                    }
                }
            } else if arg == "--header" && i + 1 < arguments.count {
                i += 1
                let headerStr = arguments[i]
                if let colonIdx = headerStr.firstIndex(of: ":") {
                    let key = headerStr[..<colonIdx].trimmingCharacters(in: .whitespaces)
                    let val = headerStr[headerStr.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty {
                        config.httpHeaders[key] = val
                    }
                }
            } else if !arg.starts(with: "-") && mediaPath == nil {
                mediaPath = arg
            }

            i += 1
        }

        return (config, mediaPath)
    }
}
