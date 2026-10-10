import AppKit
import SwiftUI

public struct JumpToTimeView: View {
    public var currentTime: Double
    public var duration: Double
    public var onJump: (Double) -> Void
    public var onCancel: () -> Void

    @State private var inputText: String = ""
    @State private var sliderValue: Double = 0.0
    @State private var isUserDraggingSlider: Bool = false
    @FocusState private var isFieldFocused: Bool

    public init(
        currentTime: Double,
        duration: Double,
        onJump: @escaping (Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.onJump = onJump
        self.onCancel = onCancel
        _sliderValue = State(initialValue: currentTime)
    }

    private var parsedTargetTime: Double? {
        if isUserDraggingSlider {
            return sliderValue
        }
        return TimeParser.parse(input: inputText, currentTime: currentTime, duration: duration)
    }

    private var targetTime: Double {
        parsedTargetTime ?? currentTime
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Jump to Time")
                        .font(.headline)
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Text("Current: \(TimeParser.format(seconds: currentTime))")
                            .font(.caption.monospaced())
                        Text("•")
                        Text("Total: \(TimeParser.format(seconds: duration))")
                            .font(.caption.monospaced())
                        if duration > 0 {
                            Text("(\(String(format: "%.1f%%", (currentTime / duration) * 100)))")
                                .font(.caption.monospaced())
                        }
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            // Input field
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("14:30, 1:15:00, +5m, or 50%", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .focused($isFieldFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isFieldFocused ? Color.accentColor : Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .onSubmit {
                            if let parsed = parsedTargetTime {
                                onJump(parsed)
                            }
                        }
                        .onChange(of: inputText) { _, newValue in
                            if !isUserDraggingSlider,
                                let parsed = TimeParser.parse(
                                    input: newValue, currentTime: currentTime, duration: duration)
                            {
                                sliderValue = parsed
                            }
                        }

                    if !inputText.isEmpty {
                        Button {
                            inputText = ""
                            sliderValue = currentTime
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Target preview badge
                HStack(spacing: 6) {
                    if let parsed = parsedTargetTime {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                        Text("Target: \(TimeParser.format(seconds: parsed))")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.white)
                        Text("(\(TimeParser.formatDiff(from: currentTime, to: parsed)))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                    } else if inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Enter timestamp (e.g. 14:30, 1:15:00, +10s, 50%)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                        Text("Invalid time format")
                            .font(.caption)
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                }
            }

            // Quick adjustment chips (adaptive layout for accessibility fonts and long durations)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    quickChip(label: "-1m") { applyOffset(-60) }
                    quickChip(label: "-10s") { applyOffset(-10) }
                    quickChip(label: "+10s") { applyOffset(10) }
                    quickChip(label: "+1m") { applyOffset(60) }

                    Spacer(minLength: 8)

                    quickChip(label: "Start (0:00)") { setTarget(0) }
                    if duration > 0 {
                        quickChip(label: "50%") { setTarget(duration * 0.5) }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        quickChip(label: "-1m") { applyOffset(-60) }
                        quickChip(label: "-10s") { applyOffset(-10) }
                        quickChip(label: "+10s") { applyOffset(10) }
                        quickChip(label: "+1m") { applyOffset(60) }
                    }
                    HStack(spacing: 6) {
                        quickChip(label: "Start (0:00)") { setTarget(0) }
                        if duration > 0 {
                            quickChip(label: "50%") { setTarget(duration * 0.5) }
                        }
                    }
                }
            }

            // Scrubbing slider
            if duration > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: $sliderValue,
                        in: 0...duration,
                        onEditingChanged: { editing in
                            isUserDraggingSlider = editing
                            if !editing {
                                inputText = TimeParser.format(seconds: sliderValue)
                            }
                        }
                    )
                    .tint(Color.accentColor)
                    .onChange(of: sliderValue) { _, newValue in
                        if isUserDraggingSlider {
                            inputText = TimeParser.format(seconds: newValue)
                        }
                    }

                    HStack {
                        Text(TimeParser.format(seconds: 0))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Text(TimeParser.format(seconds: sliderValue))
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(TimeParser.format(seconds: duration))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }

            // Bottom action buttons
            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Jump") {
                    if let parsed = parsedTargetTime {
                        onJump(parsed)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(parsedTargetTime == nil)
            }
        }
        .padding(22)
        .frame(minWidth: 420, maxWidth: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
        .defaultFocus($isFieldFocused, true)
        .onExitCommand(perform: onCancel)
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    private func quickChip(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func applyOffset(_ seconds: Double) {
        let base = parsedTargetTime ?? currentTime
        let target = min(max(base + seconds, 0), max(duration, 0))
        setTarget(target)
    }

    private func setTarget(_ target: Double) {
        sliderValue = target
        inputText = TimeParser.format(seconds: target)
    }
}
