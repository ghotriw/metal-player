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

    public init(
        enableToneMapping: Bool = true,
        defaultRenderMode: RenderMode = .auto,
        targetNits: Float = 203.0,
        sharpness: Float = 0.5,
        initialVolume: Float = 1.0,
        httpHeaders: [String: String] = [:]
    ) {
        self.enableToneMapping = enableToneMapping
        self.defaultRenderMode = defaultRenderMode
        self.targetNits = targetNits
        self.sharpness = sharpness
        self.initialVolume = initialVolume
        self.httpHeaders = httpHeaders
    }

    public static let keyEnableToneMapping = "MetalPlayer.enableToneMapping"
    public static let keyTargetNits = "MetalPlayer.targetNits"
    public static let keySharpness = "MetalPlayer.sharpness"

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
        return config
    }

    /// Saves configuration properties to UserDefaults.
    public func saveToUserDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(enableToneMapping, forKey: Self.keyEnableToneMapping)
        userDefaults.set(targetNits, forKey: Self.keyTargetNits)
        userDefaults.set(sharpness, forKey: Self.keySharpness)
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
