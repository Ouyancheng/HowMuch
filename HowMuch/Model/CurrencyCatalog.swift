import Foundation

enum CurrencyCatalog: Sendable {
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: NumberFormatter] = [:]

        func withFormatter<T>(for code: String, _ body: (NumberFormatter) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            let normalizedCode = code.uppercased()
            let formatter: NumberFormatter
            if let cached = formatters[normalizedCode] {
                formatter = cached
            } else {
                let created = NumberFormatter()
                created.locale = .current
                created.numberStyle = .currency
                created.currencyCode = normalizedCode
                formatters[normalizedCode] = created
                formatter = created
            }
            return body(formatter)
        }
    }

    private static let formatterCache = FormatterCache()

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

    static func fractionDigits(for code: String) -> Int {
        formatterCache.withFormatter(for: code) { $0.maximumFractionDigits }
    }

    static func format(_ amount: Decimal, code: String) -> String {
        let normalizedCode = code.uppercased()
        return formatterCache.withFormatter(for: normalizedCode) {
            $0.string(from: amount as NSDecimalNumber) ?? "\(amount) \(normalizedCode)"
        }
    }
}
