import Foundation

/// Approximate mid-market rates for Insights totals. Not live prices.
enum DefaultFXRates: Sendable {
    /// Units of each currency per 1 USD.
    static let unitsPerUSD: [String: Decimal] = [
        "USD": 1,
        "HKD": Decimal(string: "7.80")!,
        "CNY": Decimal(string: "7.25")!,
        "EUR": Decimal(string: "0.86")!,
        "GBP": Decimal(string: "0.74")!,
        "JPY": Decimal(string: "147")!,
        "SGD": Decimal(string: "1.28")!,
        "TWD": Decimal(string: "32")!,
        "AUD": Decimal(string: "1.53")!,
        "CAD": Decimal(string: "1.37")!,
        "KRW": Decimal(string: "1390")!,
        "MOP": Decimal(string: "8.03")!,
        "THB": Decimal(string: "32.5")!,
        "CHF": Decimal(string: "0.80")!,
        "NZD": Decimal(string: "1.68")!,
        "INR": Decimal(string: "88")!,
        "MYR": Decimal(string: "4.20")!,
        "PHP": Decimal(string: "58")!,
        "IDR": Decimal(string: "16200")!,
        "VND": Decimal(string: "25500")!,
        "DKK": Decimal(string: "6.42")!,
        "SEK": Decimal(string: "9.60")!,
        "NOK": Decimal(string: "10.10")!,
    ]

    static func convert(_ amount: Decimal, from: String, to: String) -> Decimal? {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        if fromCode == toCode {
            return amount
        }
        guard let fromRate = unitsPerUSD[fromCode], fromRate != 0,
              let toRate = unitsPerUSD[toCode] else {
            return nil
        }
        return amount * toRate / fromRate
    }
}
