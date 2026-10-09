import SwiftUI

/// A GPU-accelerated ViewModifier that applies a crisp, omnidirectional outline
/// around text or shapes using a Metal stitchable shader.
public struct SubtitleOutlineModifier: ViewModifier {
    public let radius: Double
    public let color: Color

    public init(radius: Double, color: Color = .black.opacity(0.95)) {
        self.radius = radius
        self.color = color
    }

    public func body(content: Content) -> some View {
        if radius > 0 {
            let sampleOffset = CGSize(width: ceil(radius) + 1.0, height: ceil(radius) + 1.0)
            content.layerEffect(
                ShaderLibrary.bundle(.module).subtitleOutline(
                    .float(radius),
                    .color(color)
                ),
                maxSampleOffset: sampleOffset
            )
        } else {
            content
        }
    }
}

extension View {
    /// Applies a crisp GPU-accelerated Metal outline around the view.
    public func subtitleOutline(radius: Double, color: Color = .black.opacity(0.95)) -> some View {
        modifier(SubtitleOutlineModifier(radius: radius, color: color))
    }
}
