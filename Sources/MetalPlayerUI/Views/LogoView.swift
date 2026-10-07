import SwiftUI

/// Available color themes for the player logo.
public enum LogoTheme: String, CaseIterable, Sendable {
    case emerald
    case coralPink = "coral-pink"
    case monochrome
    case monterey
    case twilight

    public var displayName: String {
        switch self {
        case .emerald: "Emerald"
        case .coralPink: "Coral Pink"
        case .monochrome: "Monochrome"
        case .monterey: "Monterey"
        case .twilight: "Twilight"
        }
    }

    public var shadowColor: Color {
        switch self {
        case .emerald:
            Color(red: 0.02, green: 0.15, blue: 0.08, opacity: 0.25)
        case .coralPink:
            Color(red: 0.22, green: 0.04, blue: 0.08, opacity: 0.25)
        case .monochrome:
            Color(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.35)
        case .monterey:
            Color(red: 0.10, green: 0.02, blue: 0.22, opacity: 0.28)
        case .twilight:
            Color(red: 0.078, green: 0.008, blue: 0.141, opacity: 0.25)
        }
    }

    public var paint0Stops: [Gradient.Stop] {
        switch self {
        case .emerald:
            [
                .init(color: Color(hex: 0x064E3B), location: 0.0),
                .init(color: Color(hex: 0x047857), location: 1.0),
            ]
        case .coralPink:
            [
                .init(color: Color(hex: 0x4C0519), location: 0.0),
                .init(color: Color(hex: 0x881337), location: 1.0),
            ]
        case .monochrome:
            [
                .init(color: Color(hex: 0x0F172A), location: 0.0),
                .init(color: Color(hex: 0x334155), location: 1.0),
            ]
        case .monterey:
            [
                .init(color: Color(hex: 0x282358), location: 0.0),
                .init(color: Color(hex: 0x3D1755), location: 1.0),
            ]
        case .twilight:
            [
                .init(color: Color(hex: 0x3B0764), location: 0.0),
                .init(color: Color(hex: 0x7E22CE), location: 1.0),
            ]
        }
    }

    public var paint1Stops: [Gradient.Stop] {
        switch self {
        case .emerald:
            [
                .init(color: Color(hex: 0x064E3B), location: 0.0),
                .init(color: Color(hex: 0x059669), location: 0.35),
                .init(color: Color(hex: 0x10B981), location: 0.7),
                .init(color: Color(hex: 0x65A30D), location: 1.0),
            ]
        case .coralPink:
            [
                .init(color: Color(hex: 0x9F1239), location: 0.0),
                .init(color: Color(hex: 0xBE123C), location: 0.25),
                .init(color: Color(hex: 0xE6434F), location: 0.55),
                .init(color: Color(hex: 0xE6434F), location: 0.85),
                .init(color: Color(hex: 0xF43F5E), location: 1.0),
            ]
        case .monochrome:
            [
                .init(color: Color(hex: 0x1E293B), location: 0.0),
                .init(color: Color(hex: 0x475569), location: 0.35),
                .init(color: Color(hex: 0x64748B), location: 0.7),
                .init(color: Color(hex: 0x94A3B8), location: 1.0),
            ]
        case .monterey:
            [
                .init(color: Color(hex: 0x25164B), location: 0.0),
                .init(color: Color(hex: 0x581C87), location: 0.3),
                .init(color: Color(hex: 0x9333EA), location: 0.65),
                .init(color: Color(hex: 0xDB2777), location: 1.0),
            ]
        case .twilight:
            [
                .init(color: Color(hex: 0x3B0764), location: 0.0),
                .init(color: Color(hex: 0x7E22CE), location: 0.35),
                .init(color: Color(hex: 0xC026D3), location: 0.7),
                .init(color: Color(hex: 0xE11D48), location: 1.0),
            ]
        }
    }

    public var paint2Stops: [Gradient.Stop] {
        switch self {
        case .emerald:
            [
                .init(color: Color(hex: 0x84CC16), location: 0.0),
                .init(color: Color(hex: 0xA3E635), location: 0.4),
                .init(color: Color(hex: 0xFACC15), location: 0.75),
                .init(color: Color(hex: 0xFEF08A), location: 1.0),
            ]
        case .coralPink:
            [
                .init(color: Color(hex: 0xE6434F), location: 0.0),
                .init(color: Color(hex: 0xFB7185), location: 0.45),
                .init(color: Color(hex: 0xFDA4AF), location: 0.8),
                .init(color: Color(hex: 0xFFE4E6), location: 1.0),
            ]
        case .monochrome:
            [
                .init(color: Color(hex: 0x94A3B8), location: 0.0),
                .init(color: Color(hex: 0xCBD5E1), location: 0.4),
                .init(color: Color(hex: 0xE2E8F0), location: 0.75),
                .init(color: Color(hex: 0xF8FAFC), location: 1.0),
            ]
        case .monterey:
            [
                .init(color: Color(hex: 0xC026D3), location: 0.0),
                .init(color: Color(hex: 0xEC4899), location: 0.4),
                .init(color: Color(hex: 0xF43F5E), location: 0.75),
                .init(color: Color(hex: 0xFB7185), location: 1.0),
            ]
        case .twilight:
            [
                .init(color: Color(hex: 0xF43F5E), location: 0.0),
                .init(color: Color(hex: 0xFB7185), location: 0.4),
                .init(color: Color(hex: 0xF59E0B), location: 0.75),
                .init(color: Color(hex: 0xFCD34D), location: 1.0),
            ]
        }
    }
}

/// Native SwiftUI representation of the MetalPlayer brand logo.
public struct LogoView: View {
    public var theme: LogoTheme

    public init(theme: LogoTheme = .emerald) {
        self.theme = theme
    }

    // Original SVG view box is 154 x 171
    private let baseWidth: CGFloat = 154
    private let baseHeight: CGFloat = 171

    public var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / baseWidth, proxy.size.height / baseHeight)
            let xOffset = (proxy.size.width - baseWidth * scale) / 2
            let yOffset = (proxy.size.height - baseHeight * scale) / 2

            Canvas { context, _ in
                context.translateBy(x: xOffset, y: yOffset)
                context.scaleBy(x: scale, y: scale)

                // 1. Clip everything to the rounded play-triangle mask
                let maskPath = PlayButtonMaskShape.path
                context.clip(to: maskPath)

                // 2. Base layer (paint0)
                let p0Grad = Gradient(stops: theme.paint0Stops)
                let p0Start = CGPoint(x: -4.26, y: 146.36)
                let p0End = CGPoint(x: 66.97, y: 130.36)
                context.fill(
                    Layer0Shape.path,
                    with: .linearGradient(p0Grad, startPoint: p0Start, endPoint: p0End)
                )

                // 3. Middle layer (paint1) with shadow
                let p1Grad = Gradient(stops: theme.paint1Stops)
                let p1Start = CGPoint(x: -0.26, y: 176.36)
                let p1End = CGPoint(x: 162.21, y: 84.86)

                context.drawLayer { subContext in
                    subContext.addFilter(.shadow(color: theme.shadowColor, radius: 5, x: -4, y: 3))
                    subContext.fill(
                        Layer1Shape.path,
                        with: .linearGradient(p1Grad, startPoint: p1Start, endPoint: p1End)
                    )
                }

                // 4. Top layer (paint2) with shadow
                let p2Grad = Gradient(stops: theme.paint2Stops)
                let p2Start = CGPoint(x: 72.74, y: 30.36)
                let p2End = CGPoint(x: 186.63, y: 129.39)

                context.drawLayer { subContext in
                    subContext.addFilter(.shadow(color: theme.shadowColor, radius: 5, x: -4, y: 3))
                    subContext.fill(
                        Layer2Shape.path,
                        with: .linearGradient(p2Grad, startPoint: p2Start, endPoint: p2End)
                    )
                }
            }
        }
        .aspectRatio(baseWidth / baseHeight, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Vector Shapes

private enum PlayButtonMaskShape {
    static var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: 30, y: 2.68))
        path.addLine(to: CGPoint(x: 143.21, y: 68.04))
        path.addCurve(
            to: CGPoint(x: 150.53, y: 75.36), control1: CGPoint(x: 146.25, y: 69.79),
            control2: CGPoint(x: 148.78, y: 72.32))
        path.addCurve(
            to: CGPoint(x: 153.21, y: 85.36), control1: CGPoint(x: 152.28, y: 78.40),
            control2: CGPoint(x: 153.21, y: 81.85))
        path.addCurve(
            to: CGPoint(x: 150.53, y: 95.36), control1: CGPoint(x: 153.21, y: 88.87),
            control2: CGPoint(x: 152.28, y: 92.32))
        path.addCurve(
            to: CGPoint(x: 143.21, y: 102.68), control1: CGPoint(x: 148.78, y: 98.40),
            control2: CGPoint(x: 146.25, y: 100.92))
        path.addLine(to: CGPoint(x: 30, y: 168.04))
        path.addCurve(
            to: CGPoint(x: 20.0, y: 170.72), control1: CGPoint(x: 26.96, y: 169.80),
            control2: CGPoint(x: 23.51, y: 170.72))
        path.addCurve(
            to: CGPoint(x: 10.0, y: 168.04), control1: CGPoint(x: 16.49, y: 170.72),
            control2: CGPoint(x: 13.04, y: 169.80))
        path.addCurve(
            to: CGPoint(x: 2.68, y: 160.72), control1: CGPoint(x: 6.96, y: 166.28),
            control2: CGPoint(x: 4.44, y: 163.76))
        path.addCurve(
            to: CGPoint(x: 0, y: 150.72), control1: CGPoint(x: 0.92, y: 157.68), control2: CGPoint(x: 0, y: 154.23))
        path.addLine(to: CGPoint(x: 0, y: 20.0))
        path.addCurve(
            to: CGPoint(x: 2.68, y: 10.0), control1: CGPoint(x: 0, y: 16.49), control2: CGPoint(x: 0.92, y: 13.04))
        path.addCurve(
            to: CGPoint(x: 10.0, y: 2.68), control1: CGPoint(x: 4.44, y: 6.96), control2: CGPoint(x: 6.96, y: 4.43))
        path.addCurve(
            to: CGPoint(x: 20.0, y: 0.0), control1: CGPoint(x: 13.04, y: 0.92), control2: CGPoint(x: 16.49, y: 0.0))
        path.addCurve(
            to: CGPoint(x: 30.0, y: 2.68), control1: CGPoint(x: 23.51, y: 0.0), control2: CGPoint(x: 26.96, y: 0.92))
        path.closeSubpath()
        return path
    }
}

private enum Layer0Shape {
    static var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: -3.25, y: 17.71))
        path.addCurve(
            to: CGPoint(x: 61.37, y: 59.97), control1: CGPoint(x: -3.25, y: -22.20),
            control2: CGPoint(x: 37.44, y: 13.02))
        path.addCurve(
            to: CGPoint(x: 13.50, y: 177.36), control1: CGPoint(x: 79.33, y: 95.19),
            control2: CGPoint(x: 49.41, y: 177.36))
        path.addCurve(
            to: CGPoint(x: -3.25, y: 17.71), control1: CGPoint(x: -10.43, y: 177.36),
            control2: CGPoint(x: -3.25, y: 83.45))
        path.closeSubpath()
        return path
    }
}

private enum Layer1Shape {
    static var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: -0.26, y: -13.64))
        path.addCurve(
            to: CGPoint(x: 106.25, y: 71.36), control1: CGPoint(x: 49.37, y: -13.64),
            control2: CGPoint(x: 101.07, y: 21.36))
        path.addCurve(
            to: CGPoint(x: 39.03, y: 176.36), control1: CGPoint(x: 111.41, y: 111.36),
            control2: CGPoint(x: 75.22, y: 146.36))
        path.addCurve(
            to: CGPoint(x: 44.20, y: 76.36), control1: CGPoint(x: 8.01, y: 156.36),
            control2: CGPoint(x: 39.03, y: 106.36))
        path.addCurve(
            to: CGPoint(x: -0.26, y: -13.64), control1: CGPoint(x: 49.37, y: 41.36),
            control2: CGPoint(x: 18.35, y: 16.36))
        path.closeSubpath()
        return path
    }
}

private enum Layer2Shape {
    static var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: 92.74, y: 30.36))
        path.addCurve(
            to: CGPoint(x: 172.74, y: 85.36), control1: CGPoint(x: 127.74, y: 50.36),
            control2: CGPoint(x: 172.74, y: 75.36))
        path.addCurve(
            to: CGPoint(x: 72.74, y: 145.36), control1: CGPoint(x: 172.74, y: 95.36),
            control2: CGPoint(x: 122.74, y: 130.36))
        path.addCurve(
            to: CGPoint(x: 92.74, y: 30.36), control1: CGPoint(x: 102.74, y: 110.36),
            control2: CGPoint(x: 107.74, y: 70.36))
        path.closeSubpath()
        return path
    }
}

// MARK: - Color Hex Extension Helper

extension Color {
    fileprivate init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
