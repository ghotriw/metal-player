import MetalPlayerCore
import SwiftUI

/// An unobtrusive real-time telemetry HUD for audio/video playback and rendering diagnostics.
/// Shows CPU, RAM, render FPS, render time per frame, and buffer queue levels.
public struct PerformanceHUDView: View {
    let engine: NativePlayerEngine

    public init(engine: NativePlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        let metrics = engine.currentMetrics
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text("ENGINE TELEMETRY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(engine.activeRenderMode == .system ? "Hardware Passthrough" : "Metal ToneMap")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(engine.activeRenderMode == .system ? Color.accentColor : Color.green)
            }
            .padding(.bottom, 2)

            // Section 1: Performance
            sectionHeader("PERFORMANCE")

            metricRow(
                label: "Process CPU:",
                value: String(format: "%.1f%%", metrics.cpuUsagePercent),
                color: metrics.cpuUsagePercent > 50 ? .orange : .white
            )

            metricRow(
                label: "Memory Footprint:",
                value: String(format: "%.1f MB", metrics.memoryUsageMB),
                color: .white
            )

            metricRow(
                label: "Render FPS:",
                value: String(format: "%.1f fps", metrics.renderFps),
                color: metrics.renderFps >= 55 ? .green : (metrics.renderFps >= 24 ? .white : .orange)
            )

            metricRow(
                label: "Frame Delivery:",
                value: String(format: "%.2f ms", metrics.renderDurationMs),
                color: metrics.renderDurationMs > 16.6 ? .orange : .white
            )

            metricRow(
                label: "Buffer Queue:",
                value: "\(metrics.frameQueueCount) frames \(metrics.isDrainPaused ? "(Paused)" : "(Feeding)")",
                color: metrics.frameQueueCount < 5 ? .red : .white
            )

            metricRow(
                label: "Dropped Frames:",
                value: "\(metrics.droppedFrames)",
                color: metrics.droppedFrames > 0 ? .orange : .white
            )

            metricRow(
                label: "A/V Sync Drift:",
                value: String(format: "%+.1f ms", metrics.avSyncDriftMs),
                color: abs(metrics.avSyncDriftMs) > 100
                    ? .red : (abs(metrics.avSyncDriftMs) > 60 ? .orange : .white)
            )

            if engine.activeRenderMode == .system {
                metricRow(
                    label: "Layer Status:",
                    value: metrics.nativeLayerStatus,
                    color: metrics.nativeLayerStatus == "Rendering" ? .green : .white
                )
            }

            // Section 2: Stream & Color Metadata
            if !metrics.resolution.isEmpty || !metrics.codecName.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.vertical, 2)

                sectionHeader("STREAM & COLOR")

                metricRow(
                    label: "Resolution:",
                    value: metrics.resolution,
                    color: .white
                )

                metricRow(
                    label: "Codec / Depth:",
                    value: "\(metrics.codecName) (\(metrics.bitDepth)-bit)",
                    color: .white
                )

                metricRow(
                    label: "Primaries / TRC:",
                    value: "\(metrics.colorPrimaries) / \(metrics.transferFunction)",
                    color: .white
                )

                if engine.activeRenderMode == .metalToneMap {
                    metricRow(
                        label: "Peak / Target:",
                        value: String(format: "%.0f → %.0f nits", metrics.sourcePeakNits, metrics.targetNits),
                        color: Color.green.opacity(0.9)
                    )
                }
            }
        }
        .padding(10)
        .frame(width: 250)
        .background(.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.top, 1)
    }

    private func metricRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
