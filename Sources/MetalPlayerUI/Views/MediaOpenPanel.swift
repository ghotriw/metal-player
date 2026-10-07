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
            .avi
        ]
        // Add common video formats supported by FFmpeg that may not be covered by system presets
        let extensions = ["mkv", "webm", "flv", "wmv", "ts", "m4v", "mov", "mp4", "ogv"]
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
