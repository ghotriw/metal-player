import MetalPlayerCore
import SwiftUI

public struct SettingsView: View {
    @AppStorage(PlayerConfiguration.keyEnableToneMapping)
    private var enableToneMapping: Bool = true

    @AppStorage(PlayerConfiguration.keySharpness)
    private var sharpness: Double = 0.5

    @AppStorage(PlayerConfiguration.keyTargetNits)
    private var targetNits: Double = 203.0

    var onConfigurationChanged: ((PlayerConfiguration) -> Void)?

    public init(onConfigurationChanged: ((PlayerConfiguration) -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
    }

    public var body: some View {
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
        .frame(width: 480, height: 320)
    }

    private func notifyChange() {
        let current = PlayerConfiguration(
            enableToneMapping: enableToneMapping,
            defaultRenderMode: .auto,
            targetNits: Float(targetNits),
            sharpness: Float(sharpness)
        )
        onConfigurationChanged?(current)
    }
}
