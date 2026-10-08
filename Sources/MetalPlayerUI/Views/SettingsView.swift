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

    @State private var showHistoryClearedAlert: Bool = false

    var onConfigurationChanged: ((PlayerConfiguration) -> Void)?

    public init(onConfigurationChanged: ((PlayerConfiguration) -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
    }

    public var body: some View {
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

                    Button("Clear Playback History", role: .destructive) {
                        PlaybackHistoryStore.shared.clearAll()
                        showHistoryClearedAlert = true
                    }
                    .alert("Playback History Cleared", isPresented: $showHistoryClearedAlert) {
                        Button("OK", role: .cancel) {}
                    }
                }
            } header: {
                Text("Playback & Resume")
            }

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
                Text("HDR & Rendering Pipeline")
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
        .frame(width: 480, height: 420)
    }

    private func notifyChange() {
        let current = PlayerConfiguration(
            enableToneMapping: enableToneMapping,
            defaultRenderMode: .auto,
            targetNits: Float(targetNits),
            sharpness: Float(sharpness),
            resumePlayback: resumePlayback,
            resumeStartThreshold: resumeStartThreshold,
            resumeEndThresholdRatio: resumeEndThresholdRatio
        )
        onConfigurationChanged?(current)
    }
}
