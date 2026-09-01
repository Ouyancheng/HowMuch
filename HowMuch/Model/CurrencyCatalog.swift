import Foundation

enum CurrencyCatalog: Sendable {
    static let featured: [String] = [
        "HKD", "CNY", "USD", "EUR", "GBP", "JPY", "SGD", "TWD", "AUD", "CAD", "KRW", "MOP", "THB", "CHF", "NZD"
    ]

    static var localeCurrency: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    static var allCodes: [String] {
        var codes = Set(featured)
        codes.insert(localeCurrency)
        if #available(iOS 16, macOS 13, *) {
            Locale.commonISOCurrencyCodes.forEach { codes.insert($0) }
        }
        return codes.sorted()
    }

    static func localizedName(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    static func displayName(for code: String) -> String {
        let name = localizedName(for: code)
        return name == code ? code : "\(code) — \(name)"
    }

    static func formatter(for code: String) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        if code == "JPY" || code == "KRW" {
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
        }
        return formatter
    }

    static func format(_ amount: Decimal, code: String) -> String {
        formatter(for: code).string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
    }
}
