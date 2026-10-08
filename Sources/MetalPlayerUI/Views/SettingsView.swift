import MetalPlayerCore
import SwiftUI

public struct SettingsView: View {
    @AppStorage(PlayerConfiguration.keyEnableToneMapping)
    private var enableToneMapping: Bool = true

    @AppStorage(PlayerConfiguration.keySharpness)
    private var sharpness: Double = 0.5

    @AppStorage(PlayerConfiguration.keyTargetNits)
    private var targetNits: Double = 203.0

    @AppStorage(PlayerConfiguration.keyResumePlayback)
    private var resumePlayback: Bool = true

    @AppStorage(PlayerConfiguration.keyResumeStartThreshold)
    private var resumeStartThreshold: Double = 15.0

    @AppStorage(PlayerConfiguration.keyResumeEndThresholdRatio)
    private var resumeEndThresholdRatio: Double = 0.95

    @AppStorage(PlayerConfiguration.keySubtitleFontSize)
    private var subtitleFontSize: Double = 24.0

    @AppStorage(PlayerConfiguration.keySubtitleTextColorHex)
    private var subtitleTextColorHex: String = "#FFFFFF"

    @AppStorage(PlayerConfiguration.keySubtitleBgColorHex)
    private var subtitleBgColorHex: String = "#000000"

    @AppStorage(PlayerConfiguration.keySubtitleBgOpacity)
    private var subtitleBgOpacity: Double = 0.65

    @State private var showHistoryClearedAlert: Bool = false
    @State private var selectedTab: SettingsTab = .subtitles

    var onConfigurationChanged: ((PlayerConfiguration) -> Void)?

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case video = "Video & HDR"
        case subtitles = "Subtitles"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .general:
                return "gearshape"
            case .video:
                return "tv"
            case .subtitles:
                return "captions.bubble"
            }
        }
    }

    public init(onConfigurationChanged: ((PlayerConfiguration) -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.iconName)
                }
                .tag(SettingsTab.general)

            videoTab
                .tabItem {
                    Label(SettingsTab.video.rawValue, systemImage: SettingsTab.video.iconName)
                }
                .tag(SettingsTab.video)

            subtitlesTab
                .tabItem {
                    Label(SettingsTab.subtitles.rawValue, systemImage: SettingsTab.subtitles.iconName)
                }
                .tag(SettingsTab.subtitles)
        }
        .frame(width: 620, height: 490)
    }

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section {
                Toggle("Remember playback position", isOn: $resumePlayback)
                    .onChange(of: resumePlayback) { _, _ in
                        notifyChange()
                    }

                if resumePlayback {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Start threshold:")
                            Spacer()
                            Text("\(Int(resumeStartThreshold))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $resumeStartThreshold, in: 0...60, step: 5)
                            .onChange(of: resumeStartThreshold) { _, _ in
                                notifyChange()
                            }
                        Text("Positions played for less than this duration start from 00:00.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("End completion threshold:")
                            Spacer()
                            Text("\(Int(resumeEndThresholdRatio * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $resumeEndThresholdRatio, in: 0.80...0.99, step: 0.01)
                            .onChange(of: resumeEndThresholdRatio) { _, _ in
                                notifyChange()
                            }
                        Text("Videos watched past this point are considered completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()
                        Button("Clear Playback History", role: .destructive) {
                            PlaybackHistoryStore.shared.clearAll()
                            showHistoryClearedAlert = true
                        }
                        .alert("Playback History Cleared", isPresented: $showHistoryClearedAlert) {
                            Button("OK", role: .cancel) {}
                        }
                    }
                }
            } header: {
                Text("Playback Resume")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Video Tab
    private var videoTab: some View {
        Form {
            Section {
                Toggle("Enable HDR Tone Mapping on SDR displays", isOn: $enableToneMapping)
                    .onChange(of: enableToneMapping) { _, _ in
                        notifyChange()
                    }

                Text(
                    enableToneMapping
                        ? "When connected to an SDR or external monitor, Metal compute shaders automatically apply ITU-R BT.2390 EETF tone mapping."
                        : "Tone mapping is globally disabled. The player strictly outputs video via Apple's native AVSampleBufferDisplayLayer."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } header: {
                Text("HDR Pipeline")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Sharpness (CAS):")
                        Spacer()
                        Text(String(format: "%.1f", sharpness))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sharpness, in: 0.0...1.0, step: 0.1)
                        .disabled(!enableToneMapping)
                        .onChange(of: sharpness) { _, _ in
                            notifyChange()
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Reference White Level:")
                        Spacer()
                        Text("\(Int(targetNits)) nits")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $targetNits, in: 100...1000, step: 10)
                        .disabled(!enableToneMapping)
                        .onChange(of: targetNits) { _, _ in
                            notifyChange()
                        }
                }
            } header: {
                Text("Tone Mapping Tuning")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Subtitles Tab
    private var subtitlesTab: some View {
        Form {
            Section {
                // Live Preview Box
                VStack(spacing: 8) {
                    HStack {
                        Text("Preview")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ZStack {
                        // Background gradient mimicking a movie scene
                        LinearGradient(
                            colors: [Color(hex: "#1e293b") ?? .gray, Color(hex: "#0f172a") ?? .black],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(.system(size: subtitleFontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(hex: subtitleTextColorHex) ?? .white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1.5)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill((Color(hex: subtitleBgColorHex) ?? .black).opacity(subtitleBgOpacity))
                            )
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Appearance Preview")
            }

            Section {
                // Font Size
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Font Size:")
                        Spacer()
                        Text("\(Int(subtitleFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $subtitleFontSize, in: 16...54, step: 2)
                        .onChange(of: subtitleFontSize) { _, _ in
                            notifyChange()
                        }
                }

                // Text Color Picker
                HStack {
                    Text("Text Color:")
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(hex: subtitleTextColorHex) ?? .white },
                            set: { newColor in
                                if let hex = newColor.toHex() {
                                    subtitleTextColorHex = hex
                                    notifyChange()
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }

                // Background Color Picker
                HStack {
                    Text("Background Box Color:")
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { Color(hex: subtitleBgColorHex) ?? .black },
                            set: { newColor in
                                if let hex = newColor.toHex() {
                                    subtitleBgColorHex = hex
                                    notifyChange()
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }

                // Background Opacity Slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Background Opacity:")
                        Spacer()
                        Text("\(Int(subtitleBgOpacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $subtitleBgOpacity, in: 0.0...1.0, step: 0.05)
                        .onChange(of: subtitleBgOpacity) { _, _ in
                            notifyChange()
                        }
                    Text("Set to 0% to completely hide the background box and display text with shadow only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Reset button
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        subtitleFontSize = 24.0
                        subtitleTextColorHex = "#FFFFFF"
                        subtitleBgColorHex = "#000000"
                        subtitleBgOpacity = 0.65
                        notifyChange()
                    }
                }
            } header: {
                Text("Typography & Style")
            }
        }
        .formStyle(.grouped)
    }

    private func notifyChange() {
        let current = PlayerConfiguration(
            enableToneMapping: enableToneMapping,
            defaultRenderMode: .auto,
            targetNits: Float(targetNits),
            sharpness: Float(sharpness),
            resumePlayback: resumePlayback,
            resumeStartThreshold: resumeStartThreshold,
            resumeEndThresholdRatio: resumeEndThresholdRatio,
            subtitleFontSize: subtitleFontSize,
            subtitleTextColorHex: subtitleTextColorHex,
            subtitleBgColorHex: subtitleBgColorHex,
            subtitleBgOpacity: subtitleBgOpacity
        )
        onConfigurationChanged?(current)
    }
}
