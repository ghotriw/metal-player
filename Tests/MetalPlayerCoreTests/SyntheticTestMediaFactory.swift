import Foundation

/// Provides automated, deterministic synthetic test media generation via FFmpeg.
/// Generates test assets dynamically into the temporary directory if not already cached.
public enum SyntheticTestMediaFactory {

    public enum Preset: String, CaseIterable, Sendable {
        /// Standard multi-track video: H.264 video with GOP=24, AC3 5.1 Surround audio, and AAC Stereo audio (30 seconds)
        case multiTrackH264
        /// Audio-only multi-channel FLAC (15 seconds)
        case audioOnlyFLAC
        /// HEVC 10-bit HDR video with BT.2020 color primaries and PQ transfer function (10 seconds)
        case hevc10BitHDR
        /// 4K HEVC 10-bit HDR10 MKV with 5 SRT subtitle tracks, first forced (3 seconds)
        case uhdHDRSubtitles

        public var filename: String {
            switch self {
            case .multiTrackH264:
                return "synth_multitrack_h264_51_stereo.mkv"
            case .audioOnlyFLAC:
                return "synth_audio_flac_51.flac"
            case .hevc10BitHDR:
                return "synth_hevc_10bit_hdr.mp4"
            case .uhdHDRSubtitles:
                return "synth_uhd_hdr_5subs.mkv"
            }
        }
    }

    private static let lock = NSLock()

    /// Resolves the absolute path to `ffmpeg` binary on the machine.
    public static func ffmpegBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Try 'which ffmpeg'
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !out.isEmpty, FileManager.default.isExecutableFile(atPath: out)
        {
            return out
        }
        return nil
    }

    /// Ensures that the specified media preset is generated and available on disk.
    /// Returns the absolute path to the ready file, or `nil` if FFmpeg is unavailable.
    public static func ensureMedia(preset: Preset = .multiTrackH264) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MetalPlayerSyntheticMedia")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let targetURL = tmpDir.appendingPathComponent(preset.filename)
        let targetPath = targetURL.path

        // Check if cached file already exists and has valid size (> 4KB)
        if FileManager.default.fileExists(atPath: targetPath),
            let attr = try? FileManager.default.attributesOfItem(atPath: targetPath),
            let size = attr[.size] as? UInt64, size > 4096
        {
            return targetPath
        }

        guard let ffmpeg = ffmpegBinaryPath() else {
            print("[SyntheticTestMediaFactory] FFmpeg not found, cannot synthesize \(preset.rawValue)")
            return nil
        }

        let arguments = arguments(for: preset, outputPath: targetPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetPath) {
                return targetPath
            } else {
                print("[SyntheticTestMediaFactory] FFmpeg failed with exit code \(process.terminationStatus)")
                return nil
            }
        } catch {
            print("[SyntheticTestMediaFactory] Failed to launch FFmpeg: \(error)")
            return nil
        }
    }

    private static func arguments(for preset: Preset, outputPath: String) -> [String] {
        switch preset {
        case .multiTrackH264:
            // 30 seconds H.264 (640x360 @ 24fps, GOP=24 with B-frames)
            // Track 1: 5.1 Surround AC3 (384k)
            // Track 2: 2.0 Stereo AAC (128k)
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=30",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=30",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24",
                "-filter_complex", "[1:a]channelmap=0|0|0|0|0|0:5.1[a1];[2:a]channelmap=0|0:stereo[a2]",
                "-map", "0:v", "-map", "[a1]", "-map", "[a2]",
                "-c:a:0", "ac3", "-b:a:0", "384k", "-metadata:s:a:0", "title=Surround 5.1", "-metadata:s:a:0",
                "language=eng",
                "-c:a:1", "aac", "-b:a:1", "128k", "-metadata:s:a:1", "title=Stereo 2.0", "-metadata:s:a:1",
                "language=ukr",
                outputPath,
            ]

        case .audioOnlyFLAC:
            // 15 seconds 5.1 Surround FLAC
            return [
                "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=15",
                "-filter_complex", "[0:a]channelmap=0|0|0|0|0|0:5.1[a]",
                "-map", "[a]",
                "-c:a", "flac",
                outputPath,
            ]

        case .uhdHDRSubtitles:
            // 3 seconds 4K HEVC Main10 HDR10 + AAC + 5 SRT subtitle tracks (first one forced)
            let dir = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
            var args: [String] = [
                "-y",
                "-f", "lavfi", "-i", "color=c=gray:size=3840x2160:rate=24:duration=3",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            ]
            for i in 0..<5 {
                let srt = dir.appendingPathComponent("synth_sub_\(i).srt")
                let text = "1\n00:00:00,000 --> 00:00:02,000\nSubtitle \(i)\n"
                try? text.write(to: srt, atomically: true, encoding: .utf8)
                args += ["-i", srt.path]
            }
            args += ["-map", "0:v", "-map", "1:a"]
            for i in 0..<5 { args += ["-map", "\(i + 2):0"] }
            args += [
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast",
                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
                "-color_range", "tv",
                "-c:a", "aac", "-b:a", "128k",
                "-c:s", "srt",
                "-metadata:s:s:0", "title=Forced", "-disposition:s:0", "forced",
                outputPath,
            ]
            return args

        case .hevc10BitHDR:
            // 10 seconds 1080p HEVC Main10, BT.2020 primaries, PQ transfer (HDR10)
            return [
                "-y",
                "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020",
                "-color_trc", "smpte2084",
                "-colorspace", "bt2020nc",
                "-c:a", "aac", "-b:a", "192k",
                outputPath,
            ]
        }
    }
}
