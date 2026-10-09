import AppKit
import UniformTypeIdentifiers

@MainActor
public enum MediaOpenPanel {
    public static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [
            .movie,
            .video,
            .quickTimeMovie,
            .mpeg4Movie,
            .avi,
            .audio,
            .mp3,
            .wav,
            .aiff,
        ]
        // Add common video and audio formats supported by FFmpeg that may not be covered by system presets
        let extensions = [
            // Video
            "mkv", "webm", "flv", "wmv", "ts", "m4v", "mov", "mp4", "ogv",
            // Audio
            "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "alac", "aif", "aiff", "wma", "ape",
        ]
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    public static func promptForMediaFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedContentTypes

        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }
}
