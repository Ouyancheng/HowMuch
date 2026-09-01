import Foundation

enum MoneyMath: Sendable {
    static func impliedRate(spend: Decimal, charged: Decimal) -> Decimal? {
        guard spend != 0 else { return nil }
        return charged / spend
    }

    static func currenciesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.uppercased() == rhs.uppercased()
    }

    static func needsExplicitReportingAmount(
        spendCurrency: String,
        chargedCurrency: String,
        reportingCurrency: String
    ) -> Bool {
        !currenciesMatch(reportingCurrency, spendCurrency)
            && !currenciesMatch(reportingCurrency, chargedCurrency)
    }

    static func reportingAmount(
        spend: Decimal,
        spendCurrency: String,
        charged: Decimal,
        chargedCurrency: String,
        reportingCurrency: String,
        override: Decimal?
    ) -> Decimal {
        if let override {
            return override
        }
        if currenciesMatch(chargedCurrency, reportingCurrency) {
            return charged
        }
        if currenciesMatch(spendCurrency, reportingCurrency) {
            return spend
        }
        return charged
    }

    /// Amount in the ledger reporting currency for Insights.
    /// Uses the stored reporting figure when it is already in that currency;
    /// otherwise converts the charged amount with default rates.
    static func insightsReportingAmount(
        spend: Decimal,
        spendCurrency: String,
        charged: Decimal,
        chargedCurrency: String,
        reportingCurrency: String,
        storedReporting: Decimal,
        storedReportingCurrency: String
    ) -> Decimal {
        if currenciesMatch(chargedCurrency, reportingCurrency) {
            return charged
        }
        if currenciesMatch(spendCurrency, reportingCurrency) {
            return spend
        }

        let storedLooksConverted = currenciesMatch(storedReportingCurrency, reportingCurrency)
            && storedReporting > 0
            && storedReporting != charged
        if storedLooksConverted {
            return storedReporting
        }

        if let converted = DefaultFXRates.convert(charged, from: chargedCurrency, to: reportingCurrency) {
            return converted
        }
        if let converted = DefaultFXRates.convert(spend, from: spendCurrency, to: reportingCurrency) {
            return converted
        }
        return storedReporting
    }

    static func formatRate(_ rate: Decimal, from: String, to: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        let value = formatter.string(from: rate as NSDecimalNumber) ?? "—"
        return "1 \(from) = \(value) \(to)"
    }
}
