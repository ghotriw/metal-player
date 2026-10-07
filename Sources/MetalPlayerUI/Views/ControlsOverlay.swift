import AppKit
import MetalPlayerCore
import SwiftUI

public struct ControlsOverlay: View {
    @Bindable var engine: NativePlayerEngine
    @Binding var isInteracting: Bool
    var onOpenFile: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragPosition: Double = 0
    @State private var isBottomHovered: Bool = false
    @State private var isTopHovered: Bool = false

    public var body: some View {
        VStack {
            // Top Header Bar: File title in line with traffic lights
            HStack(spacing: 8) {
                if !engine.mediaTitle.isEmpty {
                    Text(engine.mediaTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .frame(height: 40)
            // 78pt leading padding clears the three traffic lights (close, minimize, zoom)
            .padding(.leading, 78)
            .padding(.trailing, 20)
            .background(
                NativeVisualEffectView(material: .titlebar, blendingMode: .withinWindow)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1)
            }
            .onHover { hovering in
                isTopHovered = hovering
                updateInteractionState()
            }

            Spacer()

            // Bottom Player Control Panel (Single row)
            HStack(spacing: 14) {
                // Step frame backward
                Button {
                    engine.stepFrameBackward()
                } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Previous frame (1/24s)")

                // Seek 10s backward
                Button {
                    engine.seekRelative(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                // Play / Pause
                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                // Seek 10s forward
                Button {
                    engine.seekRelative(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                // Step frame forward
                Button {
                    engine.stepFrameForward()
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Next frame (1/24s)")

                // Current time
                Text(formatTime(isDragging ? dragPosition : engine.currentTime))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: 48, alignment: .trailing)

                // Progress Bar
                GeometryReader { geo in
                    let total = max(engine.duration, 1)
                    let current = isDragging ? dragPosition : engine.currentTime
                    let progress = min(max(current / total, 0), 1)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(height: 6)

                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * progress, height: 6)

                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .offset(x: max(0, min(geo.size.width * progress - 7, geo.size.width - 14)))
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                dragPosition = ratio * engine.duration
                            }
                            .onEnded { value in
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                let targetTime = ratio * engine.duration
                                engine.seek(to: targetTime)
                                isDragging = false
                            }
                    )
                }
                .frame(height: 18)

                // Total duration
                Text(formatTime(engine.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(minWidth: 48, alignment: .leading)

                // Volume Control
                HStack(spacing: 6) {
                    Button {
                        engine.isMuted.toggle()
                    } label: {
                        Image(
                            systemName: engine.isMuted || engine.volume == 0
                                ? "speaker.slash.fill"
                                : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Slider(value: $engine.volume, in: 0.0...1.0)
                        .frame(width: 75)
                }

                // Audio Track Selector
                if !engine.audioTracks.isEmpty {
                    Button {
                        showAudioTrackMenu()
                    } label: {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Select Audio Track")
                }

                // Render Mode (HDR / SDR) Dropdown Button
                Menu {
                    ForEach(RenderMode.allCases) { mode in
                        Button {
                            engine.renderMode = mode
                        } label: {
                            let title =
                                (mode == .auto)
                                ? "Auto (\(engine.activeRenderMode == .system ? "Apple HDR" : "Metal SDR"))"
                                : mode.rawValue
                            let isSelected = (engine.renderMode == mode)
                            Text("\(isSelected ? "✓ " : "    ")\(title)")
                        }
                    }

                    if engine.activeRenderMode == .metalToneMap {
                        Divider()
                        Menu("Sharpness: \(String(format: "%.1f", engine.metalSharpness))") {
                            Button("0.0 (Off)") { engine.metalSharpness = 0.0 }
                            Button("0.3 (Soft)") { engine.metalSharpness = 0.3 }
                            Button("0.5 (Default)") { engine.metalSharpness = 0.5 }
                            Button("0.7 (Crisp)") { engine.metalSharpness = 0.7 }
                            Button("1.0 (Maximum)") { engine.metalSharpness = 1.0 }
                        }
                    }
                } label: {
                    Text(engine.activeRenderMode == .system ? "HDR" : "SDR")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            engine.activeRenderMode == .system ? Color.accentColor : Color.white.opacity(0.85)
                        )
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .menuStyle(.borderlessButton)
                .help("Render Mode (HDR / SDR)")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                NativeVisualEffectView(material: .titlebar, blendingMode: .withinWindow)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1)
            }
            .onHover { hovering in
                isBottomHovered = hovering
                updateInteractionState()
            }
        }
        .ignoresSafeArea()
        .onChange(of: isDragging) { _, _ in
            updateInteractionState()
        }
    }

    private func updateInteractionState() {
        isInteracting = isBottomHovered || isTopHovered || isDragging
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    private func showAudioTrackMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for track in engine.audioTracks {
            let label = formatTrackTitle(track)
            let item = NSMenuItem(
                title: "\(label) (\(track.codecName), \(track.channels)ch)",
                action: #selector(AudioTrackMenuHelper.selectTrack(_:)),
                keyEquivalent: ""
            )
            item.state = (track.id == engine.selectedAudioTrackId) ? .on : .off
            let target = AudioTrackMenuHelper { [weak engine] in
                engine?.selectAudioTrack(id: track.id)
            }
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func formatTrackTitle(_ track: MediaDemuxer.AudioTrack) -> String {
        if !track.title.isEmpty {
            return track.title
        }
        if !track.language.isEmpty {
            let loc = Locale.current
            if let localized = loc.localizedString(forLanguageCode: track.language) {
                return localized.capitalized
            }
            return track.language.uppercased()
        }
        return "Track \(track.id + 1)"
    }
}

@MainActor
final class AudioTrackMenuHelper: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func selectTrack(_ sender: Any?) {
        action()
    }
}
