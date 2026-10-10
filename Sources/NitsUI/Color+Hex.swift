import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

extension Color {
    public init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }

        guard hexSanitized.count == 6 || hexSanitized.count == 8 else {
            return nil
        }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        if hexSanitized.count == 6 {
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
        } else {
            let r = Double((rgb >> 24) & 0xFF) / 255.0
            let g = Double((rgb >> 16) & 0xFF) / 255.0
            let b = Double((rgb >> 8) & 0xFF) / 255.0
            let a = Double(rgb & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
    }

    public func toHex() -> String? {
        #if canImport(AppKit)
            guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
            let r = Int(round(srgb.redComponent * 255))
            let g = Int(round(srgb.greenComponent * 255))
            let b = Int(round(srgb.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        #else
            guard let components = cgColor?.components else { return nil }
            if components.count >= 3 {
                let r = Int(round(components[0] * 255))
                let g = Int(round(components[1] * 255))
                let b = Int(round(components[2] * 255))
                return String(format: "#%02X%02X%02X", r, g, b)
            } else if components.count >= 1 {
                let val = Int(round(components[0] * 255))
                return String(format: "#%02X%02X%02X", val, val, val)
            }
            return nil
        #endif
    }
}
