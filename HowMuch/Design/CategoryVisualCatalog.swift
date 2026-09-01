import Foundation
import SwiftUI

struct RGBColorComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        red = Double((value & 0xFF0000) >> 16) / 255
        green = Double((value & 0x00FF00) >> 8) / 255
        blue = Double(value & 0x0000FF) / 255
    }

    var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }

    func contrastRatio(against other: RGBColorComponents) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var prefersBlackForeground: Bool {
        let black = RGBColorComponents(red: 0, green: 0, blue: 0)
        let white = RGBColorComponents(red: 1, green: 1, blue: 1)
        return contrastRatio(against: black) >= contrastRatio(against: white)
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

enum CategoryContrast {
    static func foreground(forHex hex: String) -> Color {
        guard let components = RGBColorComponents(hex: hex) else { return .primary }
        return components.prefersBlackForeground ? .black : .white
    }
}

struct CategoryIconOption: Identifiable, Sendable {
    let symbolName: String
    let localizedName: String
    var id: String { symbolName }

    static let all: [CategoryIconOption] = [
        .init(symbolName: "fork.knife", localizedName: String(localized: "Food", comment: "Category icon name")),
        .init(symbolName: "cart", localizedName: String(localized: "Groceries", comment: "Category icon name")),
        .init(symbolName: "cup.and.saucer", localizedName: String(localized: "Dining", comment: "Category icon name")),
        .init(symbolName: "bus", localizedName: String(localized: "Bus", comment: "Category icon name")),
        .init(symbolName: "house", localizedName: String(localized: "Home", comment: "Category icon name")),
        .init(symbolName: "bolt", localizedName: String(localized: "Utilities", comment: "Category icon name")),
        .init(symbolName: "bag", localizedName: String(localized: "Shopping", comment: "Category icon name")),
        .init(symbolName: "cross.case", localizedName: String(localized: "Health", comment: "Category icon name")),
        .init(symbolName: "book", localizedName: String(localized: "Education", comment: "Category icon name")),
        .init(symbolName: "airplane", localizedName: String(localized: "Travel", comment: "Category icon name")),
        .init(symbolName: "theatermasks", localizedName: String(localized: "Entertainment", comment: "Category icon name")),
        .init(symbolName: "repeat", localizedName: String(localized: "Recurring", comment: "Category icon name")),
        .init(symbolName: "gift", localizedName: String(localized: "Gift", comment: "Category icon name")),
        .init(symbolName: "ellipsis.circle", localizedName: String(localized: "Other", comment: "Category icon name")),
        .init(symbolName: "heart", localizedName: String(localized: "Favorite", comment: "Category icon name")),
        .init(symbolName: "car", localizedName: String(localized: "Car", comment: "Category icon name")),
        .init(symbolName: "tram", localizedName: String(localized: "Transit", comment: "Category icon name")),
        .init(symbolName: "phone", localizedName: String(localized: "Phone", comment: "Category icon name")),
        .init(symbolName: "gamecontroller", localizedName: String(localized: "Games", comment: "Category icon name")),
        .init(symbolName: "pawprint", localizedName: String(localized: "Pets", comment: "Category icon name"))
    ]

    static func localizedName(for symbolName: String) -> String {
        all.first { $0.symbolName == symbolName }?.localizedName
            ?? String(localized: "Category", comment: "Unknown category icon name")
    }
}

struct CategoryColorOption: Identifiable, Sendable {
    let hex: String
    let localizedName: String
    var id: String { hex }

    static let all: [CategoryColorOption] = [
        .init(hex: "E85D4C", localizedName: String(localized: "Coral", comment: "Category color name")),
        .init(hex: "3D9A5F", localizedName: String(localized: "Green", comment: "Category color name")),
        .init(hex: "D97706", localizedName: String(localized: "Orange", comment: "Category color name")),
        .init(hex: "2563EB", localizedName: String(localized: "Blue", comment: "Category color name")),
        .init(hex: "7C3AED", localizedName: String(localized: "Purple", comment: "Category color name")),
        .init(hex: "CA8A04", localizedName: String(localized: "Gold", comment: "Category color name")),
        .init(hex: "DB2777", localizedName: String(localized: "Pink", comment: "Category color name")),
        .init(hex: "059669", localizedName: String(localized: "Emerald", comment: "Category color name")),
        .init(hex: "4F46E5", localizedName: String(localized: "Indigo", comment: "Category color name")),
        .init(hex: "0891B2", localizedName: String(localized: "Cyan", comment: "Category color name")),
        .init(hex: "C026D3", localizedName: String(localized: "Magenta", comment: "Category color name")),
        .init(hex: "64748B", localizedName: String(localized: "Slate", comment: "Category color name"))
    ]

    static func localizedName(for hex: String) -> String {
        all.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.localizedName
            ?? String(localized: "Custom color", comment: "Unknown category color name")
    }
}
