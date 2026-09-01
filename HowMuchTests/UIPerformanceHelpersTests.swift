import CoreData
import UniformTypeIdentifiers
import XCTest
@testable import HowMuch

final class CategoryContrastTests: XCTestCase {
    func testCatalogColorsChooseWCAGForeground() throws {
        let black = try XCTUnwrap(RGBColorComponents(hex: "000000"))
        let white = try XCTUnwrap(RGBColorComponents(hex: "FFFFFF"))

        for option in CategoryColorOption.all {
            let background = try XCTUnwrap(RGBColorComponents(hex: option.hex))
            let chosen = background.prefersBlackForeground ? black : white
            XCTAssertGreaterThanOrEqual(
                background.contrastRatio(against: chosen),
                4.5,
                "\(option.localizedName) must retain normal-text contrast"
            )
        }
    }

    func testInvalidHexIsRejected() {
        XCTAssertNil(RGBColorComponents(hex: "not-a-color"))
    }
}

final class InsightsHelpersTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testLastThirtyDaysUsesCalendarDayBoundaries() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 1,
            hour: 15,
            minute: 30
        )))
        let interval = try XCTUnwrap(InsightsRange.thirtyDays.dateInterval(now: now, calendar: calendar))
        XCTAssertEqual(
            interval.start,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))
        )
        XCTAssertEqual(
            interval.end,
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
        )
        XCTAssertTrue(InsightsRange.thirtyDays.contains(interval.start, now: now, calendar: calendar))
        XCTAssertFalse(InsightsRange.thirtyDays.contains(interval.end, now: now, calendar: calendar))
    }

    func testSnapshotAggregatesEachDimensionInOnePass() {
        let expenses = [
            InsightsExpenseInput(
                categoryName: "Food",
                categoryColorHex: "E85D4C",
                spendAmount: 10,
                spendCurrency: "USD",
                chargedAmount: 10,
                chargedCurrency: "USD",
                storedReportingAmount: 10,
                storedReportingCurrency: "USD"
            ),
            InsightsExpenseInput(
                categoryName: "Food",
                categoryColorHex: "E85D4C",
                spendAmount: 5,
                spendCurrency: "USD",
                chargedAmount: 5,
                chargedCurrency: "USD",
                storedReportingAmount: 5,
                storedReportingCurrency: "USD"
            )
        ]

        let snapshot = InsightsSnapshot(expenses: expenses, reportingCode: "USD")

        XCTAssertEqual(snapshot.reportingTotal, 15)
        XCTAssertEqual(snapshot.byCategory, [
            InsightsCategoryTotal(name: "Food", symbol: "tag", colorHex: "E85D4C", total: 15)
        ])
        XCTAssertEqual(snapshot.bySpend, [InsightsCurrencyTotal(code: "USD", total: 15)])
        XCTAssertEqual(snapshot.byCharged, [InsightsCurrencyTotal(code: "USD", total: 15)])
    }
}

@MainActor
final class SearchAndExpenseModelTests: XCTestCase {
    func testSearchPredicateFiltersInCoreData() throws {
        let persistence = PersistenceController.makeTestStack()
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "USD")
        let category = ledger.activeCategories[0]
        let method = ledger.activePaymentMethods[0]
        let matching = Expense(context: persistence.viewContext)
        matching.merchant = "Corner Bakery"
        matching.ledger = ledger
        matching.category = category
        matching.paymentMethod = method
        let other = Expense(context: persistence.viewContext)
        other.merchant = "Train"
        other.ledger = ledger
        other.category = category
        other.paymentMethod = method
        persistence.save()

        let request = Expense.fetchRequest()
        request.predicate = ExpenseSearch.predicate(ledger: ledger, text: "  bakery  ")
        let results = try persistence.viewContext.fetch(request)

        XCTAssertEqual(results.map(\.objectID), [matching.objectID])
        XCTAssertEqual(ExpenseSearch.normalized("  bakery\n"), "bakery")
    }

    func testReceiptTruthComesOnlyFromData() {
        let persistence = PersistenceController.makeTestStack()
        let expense = Expense(context: persistence.viewContext)
        expense.receiptFileName = "old-name.pdf"
        expense.receiptContentType = UTType.pdf.identifier
        XCTAssertFalse(expense.hasReceipt)

        expense.receiptData = Data([0x01])
        XCTAssertTrue(expense.hasReceipt)
    }

    func testCreatorIsSetOnCreationAndNotOverwrittenOnEdit() throws {
        let persistence = PersistenceController.makeTestStack()
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "USD")
        let category = ledger.activeCategories[0]
        let method = ledger.activePaymentMethods[0]
        let values = ExpenseEditValues(
            merchant: "Cafe",
            note: "",
            occurredAt: Date(),
            spendAmount: 10,
            spendCurrency: "USD",
            chargedAmount: 10,
            chargedCurrency: "USD",
            reportingAmount: 10,
            reportingCurrency: "USD",
            receiptData: nil,
            receiptFileName: nil,
            receiptContentType: nil
        )
        let expense = try persistence.saveExpense(
            nil,
            to: ledger,
            category: category,
            paymentMethod: method,
            values: values
        )
        XCTAssertFalse((expense.createdByName ?? "").isEmpty)

        expense.createdByName = "Original Creator"
        _ = try persistence.saveExpense(
            expense,
            to: ledger,
            category: category,
            paymentMethod: method,
            values: values
        )
        XCTAssertEqual(expense.createdByName, "Original Creator")
    }
}

final class ReceiptPreviewFilesTests: XCTestCase {
    func testPreviewFilesAreUniqueAndStaleFilesAreRemoved() throws {
        let now = Date()
        let first = try ReceiptPreviewFiles.create(
            data: Data("one".utf8),
            contentType: UTType.pdf.identifier,
            id: UUID(),
            now: now.addingTimeInterval(-120)
        )
        let second = try ReceiptPreviewFiles.create(
            data: Data("two".utf8),
            contentType: UTType.pdf.identifier,
            id: UUID(),
            now: now
        )
        defer {
            ReceiptPreviewFiles.cleanup(first)
            ReceiptPreviewFiles.cleanup(second)
        }

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.lastPathComponent.contains("one"))
        XCTAssertGreaterThanOrEqual(
            ReceiptPreviewFiles.removeStale(now: now, olderThan: 60),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}

final class ReceiptSelectionAndAccessibilityTests: XCTestCase {
    func testLatestSelectionTokenRejectsStaleWork() {
        var coordinator = LatestSelectionToken()
        let first = coordinator.begin()
        let second = coordinator.begin()

        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(second))

        coordinator.invalidate()
        XCTAssertFalse(coordinator.isCurrent(second))
    }

    func testExpenseAccessibilityIncludesEveryVisibleAndContextualValue() {
        let text = ExpenseRowAccessibility.text(
            title: "Corner Cafe",
            occurredDate: "Sep 1, 2026",
            paymentMethod: "Travel Card",
            spendAmount: "$12.00",
            chargedAmount: "HK$93.00",
            category: "Dining",
            hasReceipt: true,
            author: "Taylor"
        )

        for expected in [
            "Corner Cafe", "Sep 1, 2026", "Travel Card", "$12.00",
            "HK$93.00", "Dining", "Receipt", "Taylor"
        ] {
            XCTAssertTrue(text.contains(expected), "Missing accessibility value: \(expected)")
        }
    }
}

@MainActor
final class ArchiveOpenRoutingTests: XCTestCase {
    func testLatestArchiveOpenOwnsPendingPackage() throws {
        let state = AppState()
        let firstGeneration = state.beginOpeningArchive()
        let secondGeneration = state.beginOpeningArchive()
        let first = archivePackage(marker: "first")
        let second = archivePackage(marker: "second")

        XCTAssertFalse(state.finishOpeningArchive(first, generation: firstGeneration))
        XCTAssertNil(state.pendingOpenedArchive)
        XCTAssertTrue(state.finishOpeningArchive(second, generation: secondGeneration))
        XCTAssertTrue(state.presentingSettings)
        XCTAssertFalse(state.isOpeningArchive)

        let pending = try XCTUnwrap(state.takePendingOpenedArchive())
        XCTAssertEqual(pending.package.manifest, Data("second".utf8))
        XCTAssertNil(state.pendingOpenedArchive)
    }

    func testStaleArchiveFailureCannotClearNewerOpen() {
        let state = AppState()
        let firstGeneration = state.beginOpeningArchive()
        let secondGeneration = state.beginOpeningArchive()

        XCTAssertFalse(state.failOpeningArchive(ReceiptDraftError.empty, generation: firstGeneration))
        XCTAssertTrue(state.isOpeningArchive)
        XCTAssertNil(state.archiveOpenFailure)
        XCTAssertTrue(state.finishOpeningArchive(
            archivePackage(marker: "latest"),
            generation: secondGeneration
        ))
        XCTAssertNotNil(state.pendingOpenedArchive)
    }

    private func archivePackage(marker: String) -> HowMuchEncodedArchive {
        HowMuchEncodedArchive(
            manifest: Data(marker.utf8),
            records: Data(),
            csv: Data(),
            receipts: [:]
        )
    }
}

final class CurrencyFractionTests: XCTestCase {
    func testISOFractionMetadataIsUsed() {
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "JPY"), 0)
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "IDR"), 0)
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "VND"), 0)
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "USD"), 2)
    }

    func testZeroFractionCurrenciesDoNotForceDecimals() {
        let idr = CurrencyCatalog.format(12_345, code: "IDR")
        let vnd = CurrencyCatalog.format(12_345, code: "VND")
        XCTAssertFalse(idr.contains(".00"))
        XCTAssertFalse(vnd.contains(".00"))
    }
}
