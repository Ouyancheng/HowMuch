import CoreGraphics
import CoreData
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HowMuch

@MainActor
final class ArchiveCurrencyTests: XCTestCase {
    func testArchiveRoundTripPreservesGraphAndReceipt() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Travel", kind: .household, reportingCurrency: "HKD")
        let expense = makeExpense(in: ledger, persistence: source)
        expense.merchant = "A \"quoted\", café"
        expense.receiptData = Data("%PDF-1.7\nreceipt".utf8)
        expense.receiptFileName = "receipt.pdf"
        expense.receiptContentType = UTType.pdf.identifier
        try source.viewContext.save()

        let snapshot = try source.makeArchiveSnapshot()
        let encoded = try HowMuchArchiveCodec.encode(snapshot)
        let wrapper = HowMuchArchiveDocument(package: encoded).packageWrapper()
        let decodedPackage = try HowMuchArchiveDocument.package(from: wrapper)
        let validated = try await HowMuchArchiveCodec.validate(decodedPackage)

        let destination = PersistenceController.makeTestStack()
        try clear(destination)
        try await destination.importArchive(validated, mode: .merge)

        let importedLedger = try XCTUnwrap(try destination.viewContext.fetch(Ledger.fetchRequest()).first)
        let importedExpense = try XCTUnwrap(try destination.viewContext.fetch(Expense.fetchRequest()).first)
        XCTAssertEqual(importedLedger.uuid, ledger.uuid)
        XCTAssertTrue(importedLedger.isHousehold)
        XCTAssertEqual(importedExpense.uuid, expense.uuid)
        XCTAssertEqual(importedExpense.category?.uuid, expense.category?.uuid)
        XCTAssertEqual(importedExpense.paymentMethod?.uuid, expense.paymentMethod?.uuid)
        XCTAssertEqual(importedExpense.receiptData, expense.receiptData)
        XCTAssertEqual(importedExpense.receiptContentType, UTType.pdf.identifier)
        XCTAssertTrue(importedLedger.objectID.persistentStore === destination.privateStore)
        XCTAssertTrue(importedExpense.objectID.persistentStore === destination.privateStore)
    }

    func testMergeCopiesAndReplaceModes() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Archive Name", kind: .personal, reportingCurrency: "USD")
        _ = makeExpense(in: ledger, persistence: source)
        try source.viewContext.save()
        let validated = try await archive(from: source)

        let destination = PersistenceController.makeTestStack()
        try clear(destination)
        let existing = destination.createLedger(name: "Keep Me", kind: .personal, reportingCurrency: "USD")
        existing.uuid = ledger.uuid
        try destination.viewContext.save()

        try await destination.importArchive(validated, mode: .merge)
        XCTAssertEqual(existing.name, "Keep Me")
        let mergedCount = try destination.viewContext.count(for: Ledger.fetchRequest())

        try await destination.importArchive(validated, mode: .copies)
        XCTAssertEqual(try destination.viewContext.count(for: Ledger.fetchRequest()), mergedCount + 1)
        let copied = try destination.viewContext.fetch(Ledger.fetchRequest())
            .first { $0.objectID != existing.objectID && $0.name == "Archive Name" }
        XCTAssertNotNil(copied)
        XCTAssertNotEqual(copied?.uuid, ledger.uuid)

        try await destination.importArchive(validated, mode: .replace)
        XCTAssertEqual(existing.name, "Archive Name")
        XCTAssertEqual(try destination.viewContext.count(for: Ledger.fetchRequest()), mergedCount + 1)
    }

    func testImportIntoDualStoreAlwaysUsesPrivateStore() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Family Recovery", kind: .household, reportingCurrency: "USD")
        _ = makeExpense(in: ledger, persistence: source)
        try source.viewContext.save()
        let validated = try await archive(from: source)

        let destination = PersistenceController.makeTestStack(includeSharedStore: true)
        try clear(destination)
        try await destination.importArchive(validated, mode: .merge)
        let importedLedgers = try destination.viewContext.fetch(Ledger.fetchRequest())
        let importedCategories = try destination.viewContext.fetch(Category.fetchRequest())
        let importedMethods = try destination.viewContext.fetch(PaymentMethod.fetchRequest())
        let importedExpenses = try destination.viewContext.fetch(Expense.fetchRequest())
        let allObjects: [NSManagedObject] = importedLedgers.map { $0 as NSManagedObject }
            + importedCategories.map { $0 as NSManagedObject }
            + importedMethods.map { $0 as NSManagedObject }
            + importedExpenses.map { $0 as NSManagedObject }
        XCTAssertFalse(allObjects.isEmpty)
        XCTAssertTrue(allObjects.allSatisfy { $0.objectID.persistentStore === destination.privateStore })
        XCTAssertTrue(try XCTUnwrap(allObjects.compactMap { $0 as? Ledger }.first).isHousehold)
    }

    func testMergeSharedUUIDFailsClosedButCopiesStayPrivate() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let sourceLedger = source.createLedger(name: "Collision", kind: .household, reportingCurrency: "USD")
        _ = makeExpense(in: sourceLedger, persistence: source)
        try source.viewContext.save()
        let validated = try await archive(from: source)

        let destination = PersistenceController.makeTestStack(includeSharedStore: true)
        try clear(destination)
        let sharedStore = try XCTUnwrap(destination.sharedStore)
        let sharedLedger = Ledger(context: destination.viewContext)
        destination.viewContext.assign(sharedLedger, to: sharedStore)
        sharedLedger.uuid = sourceLedger.uuid
        sharedLedger.name = "Existing Shared"
        sharedLedger.kind = LedgerKind.household.rawValue
        sharedLedger.reportingCurrency = "USD"
        try destination.viewContext.save()

        do {
            try await destination.importArchive(validated, mode: .merge)
            XCTFail("Expected shared UUID collision")
        } catch {
            guard case .sharedUUIDCollision = error as? HowMuchArchiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try destination.viewContext.fetch(Ledger.fetchRequest()).count, 1)

        try await destination.importArchive(validated, mode: .copies)
        let copiedLedger = try XCTUnwrap(
            try destination.viewContext.fetch(Ledger.fetchRequest())
                .first { $0.objectID != sharedLedger.objectID }
        )
        XCTAssertNotEqual(copiedLedger.uuid, sourceLedger.uuid)
        XCTAssertTrue(copiedLedger.objectID.persistentStore === destination.privateStore)
        XCTAssertTrue((copiedLedger.categories ?? []).allSatisfy {
            $0.objectID.persistentStore === destination.privateStore
        })
        XCTAssertTrue((copiedLedger.paymentMethods ?? []).allSatisfy {
            $0.objectID.persistentStore === destination.privateStore
        })
        XCTAssertTrue((copiedLedger.expenses ?? []).allSatisfy { expense in
            expense.objectID.persistentStore === destination.privateStore
                && expense.category?.objectID.persistentStore === destination.privateStore
                && expense.paymentMethod?.objectID.persistentStore === destination.privateStore
        })
    }

    func testReceiptValidationRejectsWrongMagic() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Receipt", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: source)
        expense.receiptData = Data("not a pdf".utf8)
        expense.receiptFileName = "bad.pdf"
        expense.receiptContentType = UTType.pdf.identifier
        try source.viewContext.save()
        let encoded = try HowMuchArchiveCodec.encode(source.makeArchiveSnapshot())
        do {
            _ = try await HowMuchArchiveCodec.validate(encoded)
            XCTFail("Expected receipt validation to fail")
        } catch {
            XCTAssertNotNil(error as? ReceiptDraftError)
        }
    }

    func testPNGReceiptImportsNormalizedJPEGBytesAndMetadata() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Image Receipt", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: source)
        let pngData = try makePNGData()
        expense.receiptData = pngData
        expense.receiptFileName = "scan.png"
        expense.receiptContentType = UTType.png.identifier
        try source.viewContext.save()

        let validated = try await archive(from: source)
        let normalized = try XCTUnwrap(validated.receipts.values.first)
        XCTAssertEqual(normalized.contentType, UTType.jpeg.identifier)
        XCTAssertEqual(URL(fileURLWithPath: normalized.fileName).pathExtension.lowercased(), "jpg")
        XCTAssertNotEqual(normalized.data, pngData)
        XCTAssertTrue(normalized.data.starts(with: [0xFF, 0xD8, 0xFF]))

        let destination = PersistenceController.makeTestStack()
        try clear(destination)
        try await destination.importArchive(validated, mode: .merge)
        let imported = try XCTUnwrap(try destination.viewContext.fetch(Expense.fetchRequest()).first)
        XCTAssertEqual(imported.receiptData, normalized.data)
        XCTAssertEqual(imported.receiptFileName, normalized.fileName)
        XCTAssertEqual(imported.receiptContentType, normalized.contentType)
    }

    func testManifestIncludesSourceMetadataAndDecodesEarlyV1WithoutIt() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        _ = source.createLedger(name: "Manifest", kind: .personal, reportingCurrency: "USD")
        try source.viewContext.save()
        var encoded = try HowMuchArchiveCodec.encode(source.makeArchiveSnapshot(includeReceipts: false))

        let manifest = try JSONDecoder().decode(HowMuchArchiveManifest.self, from: encoded.manifest)
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertFalse(try XCTUnwrap(manifest.appVersion).isEmpty)
        XCTAssertFalse(try XCTUnwrap(manifest.build).isEmpty)
        XCTAssertEqual(
            manifest.sourceFormatIdentifier,
            HowMuchArchiveManifest.currentSourceFormatIdentifier
        )

        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded.manifest) as? [String: Any]
        )
        legacyJSON["appVersion"] = nil
        legacyJSON["build"] = nil
        legacyJSON["sourceFormatIdentifier"] = nil
        encoded.manifest = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try await HowMuchArchiveCodec.validate(encoded)
        XCTAssertNil(legacy.manifest.appVersion)
        XCTAssertNil(legacy.manifest.build)
        XCTAssertNil(legacy.manifest.sourceFormatIdentifier)
    }

    func testArchiveRejectsTraversalAndUnsupportedVersion() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "Unsafe", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: source)
        expense.receiptData = Data("%PDF-1.7\nreceipt".utf8)
        expense.receiptFileName = "receipt.pdf"
        expense.receiptContentType = UTType.pdf.identifier
        try source.viewContext.save()
        var encoded = try HowMuchArchiveCodec.encode(source.makeArchiveSnapshot())

        var records = try JSONDecoder().decode(HowMuchArchiveRecords.self, from: encoded.records)
        let originalPath = try XCTUnwrap(records.expenses[0].receiptPath)
        records.expenses[0].receiptPath = "receipts/../evil.pdf"
        encoded.records = try JSONEncoder().encode(records)
        encoded.receipts["receipts/../evil.pdf"] = encoded.receipts.removeValue(forKey: originalPath)
        do {
            _ = try await HowMuchArchiveCodec.validate(encoded)
            XCTFail("Expected traversal validation to fail")
        } catch let error as HowMuchArchiveError {
            guard case .unsafePath = error else { return XCTFail("Unexpected error: \(error)") }
        }

        var clean = try HowMuchArchiveCodec.encode(source.makeArchiveSnapshot())
        var manifest = try JSONDecoder().decode(HowMuchArchiveManifest.self, from: clean.manifest)
        manifest.formatVersion = 999
        clean.manifest = try JSONEncoder().encode(manifest)
        do {
            _ = try await HowMuchArchiveCodec.validate(clean)
            XCTFail("Expected version validation to fail")
        } catch let error as HowMuchArchiveError {
            XCTAssertEqual(error, .unsupportedVersion(999))
        }
    }

    func testCSVUsesBOMCRLFAndRFC4180Escaping() throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let ledger = source.createLedger(name: "CSV", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: source)
        expense.merchant = "Shop, \"One\"\nSecond line"
        try source.viewContext.save()
        let encoded = try HowMuchArchiveCodec.encode(source.makeArchiveSnapshot(includeReceipts: false))
        XCTAssertTrue(encoded.csv.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = try XCTUnwrap(String(data: encoded.csv.dropFirst(3), encoding: .utf8))
        XCTAssertTrue(text.contains("\r\n"))
        XCTAssertTrue(text.contains("\"Shop, \"\"One\"\"\nSecond line\""))
    }

    func testReportingCurrencyKeepHistoryOnlyChangesLedger() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Currency", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.reportingAmount = 10
        expense.reportingCurrency = "USD"
        try persistence.viewContext.save()

        try persistence.updateReportingCurrency(for: ledger, to: "HKD", mode: .keepHistoricalValues)
        XCTAssertEqual(ledger.reportingCurrency, "HKD")
        XCTAssertEqual(expense.wrappedReportingAmount, 10)
        XCTAssertEqual(expense.reportingCurrency, "USD")
    }

    func testReportingCurrencyUsesDefaultRatesWhenNeitherAmountMatches() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Currency", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.spendAmount = 999
        expense.spendCurrency = "CNY"
        expense.chargedAmount = 777
        expense.chargedCurrency = "EUR"
        expense.reportingAmount = 10
        expense.reportingCurrency = "USD"
        try persistence.viewContext.save()

        let expected = MoneyMath.insightsReportingAmount(
            spend: 999,
            spendCurrency: "CNY",
            charged: 777,
            chargedCurrency: "EUR",
            reportingCurrency: "HKD",
            storedReporting: 10,
            storedReportingCurrency: "USD"
        )
        try persistence.updateReportingCurrency(for: ledger, to: "HKD", mode: .recalculateStoredFigures)
        XCTAssertEqual(expense.wrappedReportingAmount, expected)
        XCTAssertEqual(expense.reportingCurrency, "HKD")
        XCTAssertEqual(expense.wrappedSpendAmount, 999)
        XCTAssertEqual(expense.wrappedChargedAmount, 777)
    }

    func testReportingCurrencyPreservesExactChargedAndSpendMatches() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let chargedLedger = persistence.createLedger(
            name: "Charged Match",
            kind: .personal,
            reportingCurrency: "USD"
        )
        let chargedExpense = makeExpense(in: chargedLedger, persistence: persistence)
        chargedExpense.spendAmount = 11
        chargedExpense.spendCurrency = "CNY"
        chargedExpense.chargedAmount = NSDecimalNumber(string: "12.34")
        chargedExpense.chargedCurrency = "HKD"
        chargedExpense.reportingAmount = 2
        chargedExpense.reportingCurrency = "USD"

        let spendLedger = persistence.createLedger(
            name: "Spend Match",
            kind: .personal,
            reportingCurrency: "USD"
        )
        let spendExpense = makeExpense(in: spendLedger, persistence: persistence)
        spendExpense.spendAmount = NSDecimalNumber(string: "56.78")
        spendExpense.spendCurrency = "HKD"
        spendExpense.chargedAmount = 9
        spendExpense.chargedCurrency = "EUR"
        spendExpense.reportingAmount = 3
        spendExpense.reportingCurrency = "USD"
        try persistence.viewContext.save()

        try persistence.updateReportingCurrency(
            for: chargedLedger,
            to: "HKD",
            mode: .recalculateStoredFigures
        )
        try persistence.updateReportingCurrency(
            for: spendLedger,
            to: "HKD",
            mode: .recalculateStoredFigures
        )
        XCTAssertEqual(chargedExpense.wrappedReportingAmount, Decimal(string: "12.34")!)
        XCTAssertEqual(spendExpense.wrappedReportingAmount, Decimal(string: "56.78")!)
        XCTAssertEqual(chargedExpense.wrappedSpendAmount, 11)
        XCTAssertEqual(spendExpense.wrappedChargedAmount, 9)
    }

    func testReportingCurrencyPreservesExplicitOverrideAlreadyInNewCurrency() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Override", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.spendAmount = 50
        expense.spendCurrency = "CNY"
        expense.chargedAmount = 50
        expense.chargedCurrency = "USD"
        expense.reportingAmount = 400
        expense.reportingCurrency = "HKD"
        try persistence.viewContext.save()

        try persistence.updateReportingCurrency(for: ledger, to: "HKD", mode: .recalculateStoredFigures)
        XCTAssertEqual(expense.wrappedReportingAmount, 400)
        XCTAssertEqual(expense.reportingCurrency, "HKD")
        XCTAssertEqual(expense.wrappedSpendAmount, 50)
        XCTAssertEqual(expense.wrappedChargedAmount, 50)
    }

    func testReportingCurrencyPermissionIsChecked() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Currency", kind: .personal, reportingCurrency: "USD")
        _ = makeExpense(in: ledger, persistence: persistence)
        try persistence.viewContext.save()

        persistence.ledgerAccessResolverForTesting = { _ in .readOnlyParticipant }
        defer { persistence.ledgerAccessResolverForTesting = nil }
        persistence.invalidateLedgerAccess(for: ledger)
        XCTAssertThrowsError(
            try persistence.updateReportingCurrency(for: ledger, to: "EUR", mode: .keepHistoricalValues)
        ) { error in
            XCTAssertEqual(error as? LedgerAccessError, .readOnly)
        }
    }

    func testCurrencyFormattingCachePreservesISOFractionsConcurrently() async {
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "JPY"), 0)
        XCTAssertEqual(CurrencyCatalog.fractionDigits(for: "USD"), 2)
        await withTaskGroup(of: String.self) { group in
            for index in 0..<100 {
                group.addTask {
                    CurrencyCatalog.format(Decimal(index), code: index.isMultiple(of: 2) ? "USD" : "JPY")
                }
            }
            var count = 0
            for await value in group {
                XCTAssertFalse(value.isEmpty)
                count += 1
            }
            XCTAssertEqual(count, 100)
        }
    }

    func testArchiveRejectsNonPositiveAndInexactMoneyStrings() async throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Money", kind: .personal, reportingCurrency: "USD")
        _ = makeExpense(in: ledger, persistence: persistence)
        try persistence.viewContext.save()
        let baseline = try HowMuchArchiveCodec.encode(persistence.makeArchiveSnapshot())
        let invalidValues = [
            "0",
            "-1",
            "1e2",
            "1.00",
            "0.000000000000000000000000000000000000001",
            "123456789012345678901234567890123456789"
        ]

        for value in invalidValues {
            var package = baseline
            var records = try JSONDecoder().decode(HowMuchArchiveRecords.self, from: package.records)
            records.expenses[0].spendAmount = value
            package.records = try JSONEncoder().encode(records)
            do {
                _ = try await HowMuchArchiveCodec.validate(package)
                XCTFail("Expected \(value) to be rejected")
            } catch let error as HowMuchArchiveError {
                guard case .invalidValue = error else {
                    return XCTFail("Unexpected error for \(value): \(error)")
                }
            }
        }

        var reportingPackage = baseline
        var reportingRecords = try JSONDecoder().decode(
            HowMuchArchiveRecords.self,
            from: reportingPackage.records
        )
        reportingRecords.expenses[0].reportingAmount = "0"
        reportingPackage.records = try JSONEncoder().encode(reportingRecords)
        await XCTAssertThrowsArchiveValidation(reportingPackage)
    }

    func testCSVNeutralizesFormulaLeadingUserTextWithoutChangingJSON() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "CSV", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.merchant = " \t=HYPERLINK(\"https://example.invalid\")"
        expense.note = "@SUM(1,1)"
        expense.createdByName = "-2+3"
        try persistence.viewContext.save()

        let encoded = try HowMuchArchiveCodec.encode(
            persistence.makeArchiveSnapshot(includeReceipts: false)
        )
        let records = try JSONDecoder().decode(HowMuchArchiveRecords.self, from: encoded.records)
        XCTAssertEqual(records.expenses[0].merchant, expense.merchant)
        XCTAssertEqual(records.expenses[0].note, expense.note)
        XCTAssertEqual(records.expenses[0].createdByName, expense.createdByName)
        let csv = try XCTUnwrap(String(data: encoded.csv, encoding: .utf8))
        XCTAssertTrue(csv.contains("\"' \t=HYPERLINK(\"\"https://example.invalid\"\")\""))
        XCTAssertTrue(csv.contains("\"'@SUM(1,1)\""))
        XCTAssertTrue(csv.contains("\"'-2+3\""))
    }

    func testMergeRejectsCrossLedgerReusedUUIDBeforeMutationAndPreservesPendingEdits() async throws {
        let source = PersistenceController.makeTestStack()
        try clear(source)
        let sourceLedger = source.createLedger(name: "Source", kind: .personal, reportingCurrency: "USD")
        let sourceCategory = try XCTUnwrap(sourceLedger.activeCategories.first)
        _ = makeExpense(in: sourceLedger, persistence: source)
        try source.viewContext.save()
        let validated = try await archive(from: source)

        let destination = PersistenceController.makeTestStack()
        try clear(destination)
        let mappedLedger = destination.createLedger(name: "Mapped", kind: .personal, reportingCurrency: "USD")
        mappedLedger.uuid = sourceLedger.uuid
        let otherLedger = destination.createLedger(name: "Other", kind: .personal, reportingCurrency: "USD")
        otherLedger.activeCategories[0].uuid = sourceCategory.uuid
        try destination.viewContext.save()
        let ledgerCount = try destination.viewContext.count(for: Ledger.fetchRequest())
        let categoryCount = try destination.viewContext.count(for: Category.fetchRequest())

        mappedLedger.name = "Unsaved editor text"
        do {
            try await destination.importArchive(validated, mode: .merge)
            XCTFail("Expected incompatible UUID mapping")
        } catch let error as HowMuchArchiveError {
            guard case .incompatibleUUIDMapping = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(mappedLedger.name, "Unsaved editor text")
        XCTAssertTrue(destination.viewContext.hasChanges)
        XCTAssertEqual(try destination.viewContext.count(for: Ledger.fetchRequest()), ledgerCount)
        XCTAssertEqual(try destination.viewContext.count(for: Category.fetchRequest()), categoryCount)
    }

    func testReportingCurrencyUnsupportedConversionThrowsWithoutRelabeling() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Currency", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.spendCurrency = "EUR"
        expense.chargedCurrency = "CNY"
        expense.reportingAmount = 12
        expense.reportingCurrency = "USD"
        try persistence.viewContext.save()

        XCTAssertThrowsError(
            try persistence.updateReportingCurrency(
                for: ledger,
                to: "ZAR",
                mode: .recalculateStoredFigures
            )
        ) { error in
            guard case .currencyConversionUnavailable = error as? HowMuchArchiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(ledger.wrappedReportingCurrency, "USD")
        XCTAssertEqual(expense.wrappedReportingAmount, 12)
        XCTAssertEqual(expense.wrappedReportingCurrency, "USD")
    }

    func testPackageLimitsRejectOversizeCountsAndProgrammaticReceipts() async throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        _ = persistence.createLedger(name: "Limits", kind: .personal, reportingCurrency: "USD")
        try persistence.viewContext.save()
        let baseline = try HowMuchArchiveCodec.encode(
            persistence.makeArchiveSnapshot(includeReceipts: false)
        )

        var oversizedManifest = baseline
        oversizedManifest.manifest = Data(
            repeating: 0x20,
            count: HowMuchArchiveLimits.maximumManifestBytes + 1
        )
        await XCTAssertThrowsArchiveValidation(oversizedManifest)

        var excessiveCount = baseline
        var manifest = try JSONDecoder().decode(
            HowMuchArchiveManifest.self,
            from: excessiveCount.manifest
        )
        manifest.expenseCount = HowMuchArchiveLimits.maximumExpenseCount + 1
        excessiveCount.manifest = try JSONEncoder().encode(manifest)
        await XCTAssertThrowsArchiveValidation(excessiveCount)

        var excessiveReceipts = baseline
        excessiveReceipts.receipts = Dictionary(
            uniqueKeysWithValues: (0...HowMuchArchiveLimits.maximumReceiptCount).map {
                ("receipts/\($0).pdf", Data([0x25]))
            }
        )
        await XCTAssertThrowsArchiveValidation(excessiveReceipts)

        var oversizedReceipt = baseline
        oversizedReceipt.receipts = [
            "receipts/oversized.pdf": Data(
                repeating: 0x25,
                count: HowMuchArchiveLimits.maximumReceiptBytes + 1
            )
        ]
        await XCTAssertThrowsArchiveValidation(oversizedReceipt)
    }

    func testFilesystemLoaderRejectsSymlinkBeforeEagerPackageRead() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        _ = persistence.createLedger(name: "Symlink", kind: .personal, reportingCurrency: "USD")
        try persistence.viewContext.save()
        let encoded = try HowMuchArchiveCodec.encode(
            persistence.makeArchiveSnapshot(includeReceipts: false)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveSymlink-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Unsafe.howmuch", isDirectory: true)
        let externalManifest = root.appendingPathComponent("manifest.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("receipts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try encoded.manifest.write(to: externalManifest)
        try encoded.records.write(to: package.appendingPathComponent("records.json"))
        try encoded.csv.write(to: package.appendingPathComponent("expenses.csv"))
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("manifest.json"),
            withDestinationURL: externalManifest
        )

        XCTAssertThrowsError(try HowMuchArchiveDocument.loadPackage(from: package)) { error in
            guard case .unsafePath = error as? HowMuchArchiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExportRejectsIncompleteStoredReceiptMetadata() throws {
        let persistence = PersistenceController.makeTestStack()
        try clear(persistence)
        let ledger = persistence.createLedger(name: "Receipt", kind: .personal, reportingCurrency: "USD")
        let expense = makeExpense(in: ledger, persistence: persistence)
        expense.receiptData = Data("%PDF-1.7\nreceipt".utf8)
        expense.receiptFileName = nil
        expense.receiptContentType = UTType.pdf.identifier
        try persistence.viewContext.save()

        XCTAssertThrowsError(try persistence.makeArchiveSnapshot()) { error in
            guard case .invalidValue = error as? HowMuchArchiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func archive(from persistence: PersistenceController) async throws -> HowMuchValidatedArchive {
        try await HowMuchArchiveCodec.validate(
            HowMuchArchiveCodec.encode(persistence.makeArchiveSnapshot())
        )
    }

    private func XCTAssertThrowsArchiveValidation(
        _ package: HowMuchEncodedArchive,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await HowMuchArchiveCodec.validate(package)
            XCTFail("Expected archive validation to fail", file: file, line: line)
        } catch {
            XCTAssertNotNil(error as? HowMuchArchiveError, file: file, line: line)
        }
    }

    @discardableResult
    private func makeExpense(in ledger: Ledger, persistence: PersistenceController) -> Expense {
        let expense = Expense(context: persistence.viewContext)
        persistence.assign(expense, toSameStoreAs: ledger)
        expense.occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        expense.merchant = "Merchant"
        expense.note = "Note"
        expense.spendAmount = 12
        expense.spendCurrency = "USD"
        expense.chargedAmount = 12
        expense.chargedCurrency = "USD"
        expense.reportingAmount = 12
        expense.reportingCurrency = ledger.wrappedReportingCurrency
        expense.createdAt = Date(timeIntervalSince1970: 1_700_000_001)
        expense.updatedAt = Date(timeIntervalSince1970: 1_700_000_002)
        expense.createdByName = "Tester"
        expense.ledger = ledger
        expense.category = ledger.activeCategories[0]
        expense.paymentMethod = ledger.activePaymentMethods[0]
        return expense
    }

    private func makePNGData() throws -> Data {
        let pixels = Data([
            0xFF, 0x00, 0x00, 0xFF,
            0x00, 0xFF, 0x00, 0xFF,
            0x00, 0x00, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF
        ])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func clear(_ persistence: PersistenceController) throws {
        let context = persistence.viewContext
        for entityName in ["Expense", "Category", "PaymentMethod", "Ledger"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in try context.fetch(request) {
                context.delete(object)
            }
        }
        try context.save()
    }
}
