import XCTest
@testable import HowMuch

final class MoneyMathTests: XCTestCase {
    func testImpliedRate() {
        let rate = MoneyMath.impliedRate(spend: Decimal(string: "88")!, charged: Decimal(string: "96.5")!)
        XCTAssertEqual(rate, Decimal(string: "96.5")! / Decimal(88))
    }

    func testImpliedRateZeroSpend() {
        XCTAssertNil(MoneyMath.impliedRate(spend: 0, charged: 10))
    }

    func testReportingUsesChargedWhenCurrenciesMatch() {
        let amount = MoneyMath.reportingAmount(
            spend: 88,
            spendCurrency: "CNY",
            charged: Decimal(string: "96.5")!,
            chargedCurrency: "HKD",
            reportingCurrency: "HKD",
            override: nil
        )
        XCTAssertEqual(amount, Decimal(string: "96.5")!)
    }

    func testReportingUsesSpendWhenReportingMatchesSpend() {
        let amount = MoneyMath.reportingAmount(
            spend: 88,
            spendCurrency: "CNY",
            charged: Decimal(string: "96.5")!,
            chargedCurrency: "HKD",
            reportingCurrency: "CNY",
            override: nil
        )
        XCTAssertEqual(amount, 88)
    }

    func testReportingUsesOverrideWhenNeitherMatches() {
        XCTAssertTrue(
            MoneyMath.needsExplicitReportingAmount(
                spendCurrency: "CNY",
                chargedCurrency: "HKD",
                reportingCurrency: "USD"
            )
        )
        let amount = MoneyMath.reportingAmount(
            spend: 88,
            spendCurrency: "CNY",
            charged: Decimal(string: "96.5")!,
            chargedCurrency: "HKD",
            reportingCurrency: "USD",
            override: Decimal(string: "12.4")!
        )
        XCTAssertEqual(amount, Decimal(string: "12.4")!)
    }

    func testSameCurrencyDoesNotNeedOverride() {
        XCTAssertFalse(
            MoneyMath.needsExplicitReportingAmount(
                spendCurrency: "HKD",
                chargedCurrency: "hkd",
                reportingCurrency: "HKD"
            )
        )
    }

    func testFormatRate() {
        let text = MoneyMath.formatRate(Decimal(string: "1.0966")!, from: "CNY", to: "HKD")
        XCTAssertTrue(text.contains("CNY"))
        XCTAssertTrue(text.contains("HKD"))
    }

    func testDefaultRatesConvertViaUSD() {
        let hkd = DefaultFXRates.convert(50, from: "USD", to: "HKD")
        XCTAssertEqual(hkd, Decimal(string: "390"))
        let back = DefaultFXRates.convert(Decimal(string: "390")!, from: "HKD", to: "USD")
        XCTAssertEqual(back, 50)
    }

    func testDefaultRatesSameCurrency() {
        XCTAssertEqual(DefaultFXRates.convert(88, from: "CNY", to: "cny"), 88)
    }

    func testDefaultRatesUnknownCurrency() {
        XCTAssertNil(DefaultFXRates.convert(10, from: "XYZ", to: "HKD"))
    }

    func testFeaturedCurrenciesHaveDefaultRates() {
        for code in CurrencyCatalog.featured {
            XCTAssertNotNil(DefaultFXRates.unitsPerUSD[code], "Missing default rate for \(code)")
        }
    }

    func testInsightsUsesChargedWhenReportingMatches() {
        let amount = MoneyMath.insightsReportingAmount(
            spend: 88,
            spendCurrency: "CNY",
            charged: Decimal(string: "96.5")!,
            chargedCurrency: "HKD",
            reportingCurrency: "HKD",
            storedReporting: Decimal(string: "96.5")!,
            storedReportingCurrency: "HKD"
        )
        XCTAssertEqual(amount, Decimal(string: "96.5")!)
    }

    func testInsightsConvertsWhenStoredReportingIsUnconvertedCharged() {
        let amount = MoneyMath.insightsReportingAmount(
            spend: 50,
            spendCurrency: "USD",
            charged: 50,
            chargedCurrency: "USD",
            reportingCurrency: "HKD",
            storedReporting: 50,
            storedReportingCurrency: "HKD"
        )
        XCTAssertEqual(amount, Decimal(string: "390"))
    }

    func testInsightsPrefersExplicitOverride() {
        let amount = MoneyMath.insightsReportingAmount(
            spend: 50,
            spendCurrency: "USD",
            charged: 50,
            chargedCurrency: "USD",
            reportingCurrency: "HKD",
            storedReporting: Decimal(string: "400")!,
            storedReportingCurrency: "HKD"
        )
        XCTAssertEqual(amount, Decimal(string: "400")!)
    }
}

final class CurrencyCatalogTests: XCTestCase {
    func testFormatIncludesCodeOrSymbol() {
        let text = CurrencyCatalog.format(88, code: "CNY")
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("88") || text.contains("88.00") || text.contains("88.0"))
    }

    func testFeaturedContainsRegionalCurrencies() {
        XCTAssertTrue(CurrencyCatalog.featured.contains("HKD"))
        XCTAssertTrue(CurrencyCatalog.featured.contains("CNY"))
        XCTAssertTrue(CurrencyCatalog.featured.contains("USD"))
    }
}
