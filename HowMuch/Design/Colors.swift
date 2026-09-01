import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        default:
            r = 0.35; g = 0.55; b = 0.93
        }
        self.init(red: r, green: g, blue: b)
    }

    func hexString() -> String {
        let resolved = NSColorCompatible(self)
        return resolved
    }
}

#if os(macOS)
import AppKit

private func NSColorCompatible(_ color: Color) -> String {
    let ns = NSColor(color)
    guard let rgb = ns.usingColorSpace(.deviceRGB) else { return "5B8DEF" }
    return String(
        format: "%02X%02X%02X",
        Int((rgb.redComponent * 255).rounded()),
        Int((rgb.greenComponent * 255).rounded()),
        Int((rgb.blueComponent * 255).rounded())
    )
}
#else
import UIKit

private func NSColorCompatible(_ color: Color) -> String {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(
        format: "%02X%02X%02X",
        Int((r * 255).rounded()),
        Int((g * 255).rounded()),
        Int((b * 255).rounded())
    )
}
#endif
