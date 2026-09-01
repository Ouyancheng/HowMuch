import CoreData
import XCTest
@testable import HowMuch

@MainActor
final class StoreMigrationFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        let ledgerName: String
        let ledgerUUID: UUID
        let categoryName: String
        let categoryUUID: UUID
        let paymentMethodName: String
        let paymentMethodUUID: UUID
        let expenseUUID: UUID
        let merchant: String
        let amount: String
        let currency: String
    }

    func testLegacySQLiteFixtureLightweightMigratesIntoLocalStore() throws {
        let fixture = try loadFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HowMuchMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try materializeLegacyStore(fixture, at: root.appendingPathComponent("private.sqlite"))
        let persistence = PersistenceController.makeLocalTestStack(applicationSupportDirectory: root)

        XCTAssertEqual(persistence.loadState, .loaded)
        XCTAssertTrue(persistence.isLocalOnly)
        let ledger = try XCTUnwrap(try persistence.viewContext.fetch(Ledger.fetchRequest()).first)
        let expense = try XCTUnwrap(try persistence.viewContext.fetch(Expense.fetchRequest()).first)
        XCTAssertEqual(ledger.uuid, fixture.ledgerUUID)
        XCTAssertEqual(ledger.wrappedName, fixture.ledgerName)
        XCTAssertEqual(ledger.wrappedReportingCurrency, fixture.currency)
        XCTAssertEqual(expense.uuid, fixture.expenseUUID)
        XCTAssertEqual(expense.wrappedMerchant, fixture.merchant)
        XCTAssertEqual(expense.wrappedSpendAmount, try XCTUnwrap(Decimal(string: fixture.amount)))
        XCTAssertEqual(expense.ledger?.objectID, ledger.objectID)
        XCTAssertEqual(expense.category?.uuid, fixture.categoryUUID)
        XCTAssertEqual(expense.paymentMethod?.uuid, fixture.paymentMethodUUID)
        XCTAssertNil(expense.receiptData)
        XCTAssertFalse(try XCTUnwrap(expense.category).isArchived)
        XCTAssertFalse(try XCTUnwrap(expense.paymentMethod).isArchived)
    }

    private func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "LegacyStore-v0",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "LegacyStore-v0", withExtension: "json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: try XCTUnwrap(url)))
    }

    private func materializeLegacyStore(_ fixture: Fixture, at url: URL) throws {
        let model = try XCTUnwrap(
            PersistenceController.managedObjectModel.copy() as? NSManagedObjectModel
        )
        let removedProperties: [String: Set<String>] = [
            "Ledger": ["reportingCurrency"],
            "Category": ["isArchived", "symbolName"],
            "PaymentMethod": ["isArchived"],
            "Expense": [
                "createdByName", "receiptContentType", "receiptData", "receiptFileName",
                "reportingAmount", "reportingCurrency"
            ]
        ]
        for (entityName, names) in removedProperties {
            let entity = try XCTUnwrap(model.entitiesByName[entityName])
            entity.properties = entity.properties.filter { !names.contains($0.name) }
        }
        for entity in model.entities {
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        }
        model.versionIdentifiers = ["HowMuch-v0"]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        let ledger = NSEntityDescription.insertNewObject(forEntityName: "Ledger", into: context)
        ledger.setValue(fixture.ledgerUUID, forKey: "uuid")
        ledger.setValue(fixture.ledgerName, forKey: "name")
        ledger.setValue(LedgerKind.personal.rawValue, forKey: "kind")

        let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context)
        category.setValue(fixture.categoryUUID, forKey: "uuid")
        category.setValue(fixture.categoryName, forKey: "name")
        category.setValue(ledger, forKey: "ledger")

        let method = NSEntityDescription.insertNewObject(forEntityName: "PaymentMethod", into: context)
        method.setValue(fixture.paymentMethodUUID, forKey: "uuid")
        method.setValue(fixture.paymentMethodName, forKey: "name")
        method.setValue(fixture.currency, forKey: "billingCurrency")
        method.setValue(PaymentKind.cash.rawValue, forKey: "kind")
        method.setValue(ledger, forKey: "ledger")

        let expense = NSEntityDescription.insertNewObject(forEntityName: "Expense", into: context)
        expense.setValue(fixture.expenseUUID, forKey: "uuid")
        expense.setValue(fixture.merchant, forKey: "merchant")
        expense.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "occurredAt")
        expense.setValue(NSDecimalNumber(string: fixture.amount), forKey: "spendAmount")
        expense.setValue(fixture.currency, forKey: "spendCurrency")
        expense.setValue(NSDecimalNumber(string: fixture.amount), forKey: "chargedAmount")
        expense.setValue(fixture.currency, forKey: "chargedCurrency")
        expense.setValue(ledger, forKey: "ledger")
        expense.setValue(category, forKey: "category")
        expense.setValue(method, forKey: "paymentMethod")

        try context.save()
        context.reset()
        try coordinator.remove(store)
    }
}

@MainActor
final class ReleasePerformanceTests: XCTestCase {
    func testInsightsSnapshotPerformanceWithModerateFixture() {
        var expenses: [InsightsExpenseInput] = []
        expenses.reserveCapacity(4_000)
        for index in 0..<4_000 {
            let categoryName = "Category \(index % 8)"
            let spendAmount = Decimal(index % 97 + 1)
            let chargedAmount = Decimal(index % 89 + 1)
            let reportingAmount = Decimal(index % 83 + 1)
            expenses.append(InsightsExpenseInput(
                categoryName: categoryName,
                categorySymbol: "tag",
                categoryColorHex: "64748B",
                spendAmount: spendAmount,
                spendCurrency: index.isMultiple(of: 3) ? "USD" : "HKD",
                chargedAmount: chargedAmount,
                chargedCurrency: index.isMultiple(of: 2) ? "USD" : "HKD",
                storedReportingAmount: reportingAmount,
                storedReportingCurrency: "USD"
            ))
        }
        XCTAssertEqual(InsightsSnapshot(expenses: expenses, reportingCode: "USD").byCategory.count, 8)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = InsightsSnapshot(expenses: expenses, reportingCode: "USD")
        }
    }

    func testArchiveSnapshotAndEncodingPerformanceWithModerateFixture() throws {
        let persistence = PersistenceController.makeTestStack()
        let ledger = persistence.createLedger(name: "Performance", kind: .personal, reportingCurrency: "USD")
        let category = try XCTUnwrap(ledger.activeCategories.first)
        let method = try XCTUnwrap(ledger.activePaymentMethods.first)
        for index in 0..<300 {
            let expense = Expense(context: persistence.viewContext)
            expense.uuid = UUID()
            expense.occurredAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            expense.merchant = "Merchant \(index % 20)"
            expense.note = "Deterministic fixture"
            expense.spendAmount = NSDecimalNumber(value: (index % 100) + 1)
            expense.spendCurrency = "USD"
            expense.chargedAmount = expense.spendAmount
            expense.chargedCurrency = "USD"
            expense.reportingAmount = expense.spendAmount
            expense.reportingCurrency = "USD"
            expense.ledger = ledger
            expense.category = category
            expense.paymentMethod = method
        }
        try persistence.viewContext.save()
        XCTAssertEqual(try persistence.viewContext.count(for: Expense.fetchRequest()), 300)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            let snapshot = try! persistence.makeArchiveSnapshot(includeReceipts: false)
            _ = try! HowMuchArchiveCodec.encode(snapshot)
        }
    }
}
