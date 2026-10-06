import SwiftUI
import AppKit
import MetalPlayerCore

public struct ControlsOverlay: View {
    @Bindable var engine: NativePlayerEngine
    @Binding var isInteracting: Bool
    var onOpenFile: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragPosition: Double = 0
    @State private var jumpTimeText: String = ""
    @FocusState private var isFieldFocused: Bool

    public var body: some View {
        VStack {
            // Top Header Bar
            HStack(spacing: 12) {
                if !engine.mediaTitle.isEmpty {
                    Text(engine.mediaTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(radius: 4)
                }

                Spacer()

                // Render Mode Switcher
                Picker("Render Mode", selection: $engine.renderMode) {
                    ForEach(RenderMode.allCases) { mode in
                        if mode == .auto {
                            Text("Auto (\(engine.activeRenderMode == .system ? "Apple HDR" : "Metal SDR"))").tag(mode)
                        } else {
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 480)

                Button {
                    onOpenFile()
                } label: {
                    Label("Open File", systemImage: "folder")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer()

            // Bottom Player Control Panel
            VStack(spacing: 10) {
                // Seek Bar Slider
                GeometryReader { geo in
                    let total = max(engine.duration, 1)
                    let current = isDragging ? dragPosition : engine.currentTime
                    let progress = min(max(current / total, 0), 1)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                            .frame(height: 5)

                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * progress, height: 5)

                        Circle()
                            .fill(.white)
                            .frame(width: 13, height: 13)
                            .offset(x: max(0, min(geo.size.width * progress - 6.5, geo.size.width - 13)))
                    }
                    .frame(height: 16)
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
                .frame(height: 16)

                // Bottom row: Time, Controls
                HStack(spacing: 16) {
                    // Play/Pause
                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    // Step frame backward
                    Button {
                        engine.stepFrameBackward()
                    } label: {
                        Image(systemName: "backward.frame.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Previous frame (1/24s)")

                    // Seek 10s backward
                    Button {
                        engine.seekRelative(by: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button {
                        engine.seekRelative(by: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    // Step frame forward
                    Button {
                        engine.stepFrameForward()
                    } label: {
                        Image(systemName: "forward.frame.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Next frame (1/24s)")

                    // Time display & Exact jump input
                    Text("\(formatTime(isDragging ? dragPosition : engine.currentTime)) / \(formatTime(engine.duration))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))

                    // Exact time jump
                    HStack(spacing: 6) {
                        TextField("00:00", text: $jumpTimeText)
                            .focused($isFieldFocused)
                            .textFieldStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 58)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit {
                                performJump()
                            }
                            .onChange(of: isFieldFocused) { _, focused in
                                isInteracting = focused
                            }
                            .onChange(of: jumpTimeText) { _, text in
                                if !text.isEmpty {
                                    isInteracting = true
                                }
                            }

                        Button("Jump") {
                            performJump()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.3))
                    }

                    if engine.activeRenderMode == .metalToneMap {
                        HStack(spacing: 6) {
                            Text("Sharpness:")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                            Slider(value: $engine.metalSharpness, in: 0.0...1.0, step: 0.05)
                                .frame(width: 90)
                            Text(String(format: "%.1f", engine.metalSharpness))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Spacer()

                    // Audio Track Selector (if media has multiple audio tracks)
                    if !engine.audioTracks.isEmpty {
                        Menu {
                            ForEach(engine.audioTracks) { track in
                                Button {
                                    engine.selectAudioTrack(id: track.id)
                                } label: {
                                    HStack {
                                        let label = formatTrackTitle(track)
                                        Text("\(label) (\(track.codecName), \(track.channels)ch)")
                                        if track.id == engine.selectedAudioTrackId {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "waveform.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Select Audio Track")
                    }

                    // Volume & Mute Control
                    HStack(spacing: 6) {
                        Button {
                            engine.isMuted.toggle()
                        } label: {
                            Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : (engine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)

                        Slider(value: $engine.volume, in: 0.0...1.0)
                            .frame(width: 70)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
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

    private func performJump() {
        let trimmed = jumpTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var targetSeconds: Double = 0
        let parts = trimmed.split(separator: ":").map { String($0) }
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            targetSeconds = h * 3600 + m * 60 + s
        } else if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
            targetSeconds = m * 60 + s
        } else if let s = Double(trimmed) {
            targetSeconds = s
        }

        let clamped = max(0, min(targetSeconds, engine.duration))
        engine.seek(to: clamped)
        jumpTimeText = ""
        isFieldFocused = false
        isInteracting = false
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
