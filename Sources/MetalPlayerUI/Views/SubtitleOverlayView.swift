import MetalPlayerCore
import SwiftUI

public struct SubtitleOverlayView: View {
    public let cues: [SubtitleCue]
    public let fontSize: Double
    public let textColor: Color
    public let backgroundColor: Color
    public let backgroundOpacity: Double

    public init(
        cues: [SubtitleCue],
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65
    ) {
        self.cues = cues
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
    }

    public init(
        cue: SubtitleCue?,
        fontSize: Double = 24.0,
        textColor: Color = .white,
        backgroundColor: Color = .black,
        backgroundOpacity: Double = 0.65
    ) {
        self.init(
            cues: cue.map { [$0] } ?? [],
            fontSize: fontSize,
            textColor: textColor,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
    }

    private var topCues: [SubtitleCue] {
        cues.filter { isTopAligned($0.alignment) }
    }

    private var centerCues: [SubtitleCue] {
        cues.filter { $0.alignment == .center }
    }

    private var bottomCues: [SubtitleCue] {
        cues.filter { !isTopAligned($0.alignment) && $0.alignment != .center }
    }

    public var body: some View {
        if !cues.isEmpty {
            VStack(spacing: 8) {
                // Top aligned cues
                if !topCues.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(topCues) { cue in
                            cueRow(cue)
                        }
                    }
                    .padding(.top, 48)
                }

                Spacer()

                // Center aligned cues
                if !centerCues.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(centerCues) { cue in
                            cueRow(cue)
                        }
                    }
                }

                Spacer()

                // Bottom aligned cues
                if !bottomCues.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(bottomCues) { cue in
                            cueRow(cue)
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
        }
    }

    @ViewBuilder
    private func cueRow(_ cue: SubtitleCue) -> some View {
        HStack {
            if isTrailingAligned(cue.alignment) {
                Spacer()
            }

            subtitleLabel(cue.text, textAlignment: textAlignment(for: cue.alignment))

            if isLeadingAligned(cue.alignment) {
                Spacer()
            }
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func subtitleLabel(_ text: String, textAlignment: TextAlignment) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .multilineTextAlignment(textAlignment)
            .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1.5)
            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor.opacity(backgroundOpacity))
            )
    }

    private func isTopAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topCenter || alignment == .topLeft || alignment == .topRight
    }

    private func isLeadingAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topLeft || alignment == .bottomLeft
    }

    private func isTrailingAligned(_ alignment: SubtitleAlignment) -> Bool {
        alignment == .topRight || alignment == .bottomRight
    }

    private func textAlignment(for alignment: SubtitleAlignment) -> TextAlignment {
        if isLeadingAligned(alignment) {
            return .leading
        } else if isTrailingAligned(alignment) {
            return .trailing
        }
        return .center
    }
}
