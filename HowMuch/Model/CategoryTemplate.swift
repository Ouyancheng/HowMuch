import Foundation

struct CategoryTemplate: Sendable, Identifiable {
    let name: String
    let symbolName: String
    let colorHex: String
    var id: String { name }

    static let defaults: [CategoryTemplate] = [
        .init(name: String(localized: "Food", comment: "Default category"), symbolName: "fork.knife", colorHex: "E85D4C"),
        .init(name: String(localized: "Groceries", comment: "Default category"), symbolName: "cart", colorHex: "3D9A5F"),
        .init(name: String(localized: "Dining", comment: "Default category"), symbolName: "cup.and.saucer", colorHex: "D97706"),
        .init(name: String(localized: "Transport", comment: "Default category"), symbolName: "bus", colorHex: "2563EB"),
        .init(name: String(localized: "Housing", comment: "Default category"), symbolName: "house", colorHex: "7C3AED"),
        .init(name: String(localized: "Utilities", comment: "Default category"), symbolName: "bolt", colorHex: "CA8A04"),
        .init(name: String(localized: "Shopping", comment: "Default category"), symbolName: "bag", colorHex: "DB2777"),
        .init(name: String(localized: "Health", comment: "Default category"), symbolName: "cross.case", colorHex: "059669"),
        .init(name: String(localized: "Education", comment: "Default category"), symbolName: "book", colorHex: "4F46E5"),
        .init(name: String(localized: "Travel", comment: "Default category"), symbolName: "airplane", colorHex: "0891B2"),
        .init(name: String(localized: "Entertainment", comment: "Default category"), symbolName: "theatermasks", colorHex: "C026D3"),
        .init(name: String(localized: "Subscriptions", comment: "Default category"), symbolName: "repeat", colorHex: "64748B"),
        .init(name: String(localized: "Gifts", comment: "Default category"), symbolName: "gift", colorHex: "E11D48"),
        .init(name: String(localized: "Other", comment: "Default category"), symbolName: "ellipsis.circle", colorHex: "6B7280")
    ]
}
