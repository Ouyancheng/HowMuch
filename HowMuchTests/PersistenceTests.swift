import CoreData
import XCTest
@testable import HowMuch

@MainActor
final class PersistenceTests: XCTestCase {
    /// Retained for the process lifetime so XCTest's post-test memory checker
    /// does not tear down an in-memory Core Data stack mid-dealloc.
    private static let stack = PersistenceController(inMemory: true, enableCloudKit: false)

    override func setUp() {
        super.setUp()
        let context = Self.stack.viewContext
        context.registeredObjects.forEach(context.delete)
        Self.stack.save()
    }

    func testInMemoryBootstrapCreatesPersonalLedger() throws {
        Self.stack.bootstrapIfNeeded()
        let request = Ledger.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
        let count = try Self.stack.viewContext.count(for: request)
        XCTAssertEqual(count, 1)
        let categories = try Self.stack.viewContext.count(for: Category.fetchRequest())
        let methods = try Self.stack.viewContext.count(for: PaymentMethod.fetchRequest())
        XCTAssertGreaterThan(categories, 0)
        XCTAssertGreaterThan(methods, 0)
    }

    func testDualCurrencyExpenseSnapshot() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let category = ledger.activeCategories[0]
        let method = ledger.activePaymentMethods[0]
        method.billingCurrency = "HKD"

        let expense = Expense(context: persistence.viewContext)
        expense.spendAmount = 88
        expense.spendCurrency = "CNY"
        expense.chargedAmount = NSDecimalNumber(decimal: Decimal(string: "96.5")!)
        expense.chargedCurrency = "HKD"
        expense.reportingAmount = MoneyMath.reportingAmount(
            spend: 88,
            spendCurrency: "CNY",
            charged: Decimal(string: "96.5")!,
            chargedCurrency: "HKD",
            reportingCurrency: "HKD",
            override: nil
        ) as NSDecimalNumber
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = category
        expense.paymentMethod = method
        persistence.save()

        XCTAssertTrue(expense.isDualCurrency)
        XCTAssertEqual(expense.wrappedReportingAmount, Decimal(string: "96.5")!)
        XCTAssertNotNil(expense.impliedRate)
    }

    func testArchiveCategoryKeepsExpense() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let category = ledger.activeCategories[0]
        let method = ledger.activePaymentMethods[0]
        let expense = Expense(context: persistence.viewContext)
        expense.spendAmount = 10
        expense.chargedAmount = 10
        expense.reportingAmount = 10
        expense.spendCurrency = "HKD"
        expense.chargedCurrency = "HKD"
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = category
        expense.paymentMethod = method
        persistence.save()

        category.isArchived = true
        persistence.save()

        XCTAssertTrue(category.isArchived)
        XCTAssertEqual(expense.category, category)
        XCTAssertFalse(ledger.activeCategories.contains(where: { $0.objectID == category.objectID }))
    }

    func testRemoveUnusedCategoryDeletes() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let extra = Category(context: persistence.viewContext)
        persistence.assign(extra, toSameStoreAs: ledger)
        extra.name = "Temp"
        extra.ledger = ledger
        persistence.save()
        let extraID = extra.objectID

        XCTAssertNil(persistence.removeCategory(extra))
        let leftover = Category.fetchRequest()
        leftover.predicate = NSPredicate(format: "name == %@", "Temp")
        XCTAssertEqual(try persistence.viewContext.count(for: leftover), 0)
        XCTAssertFalse(ledger.activeCategories.contains(where: { $0.objectID == extraID }))
    }

    func testRemoveUsedCategoryArchives() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let category = ledger.activeCategories[0]
        let method = ledger.activePaymentMethods[0]
        let expense = Expense(context: persistence.viewContext)
        expense.spendAmount = 10
        expense.chargedAmount = 10
        expense.reportingAmount = 10
        expense.spendCurrency = "HKD"
        expense.chargedCurrency = "HKD"
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = category
        expense.paymentMethod = method
        persistence.save()

        XCTAssertNil(persistence.removeCategory(category))
        XCTAssertFalse(category.isDeleted)
        XCTAssertTrue(category.isArchived)
        XCTAssertEqual(expense.category, category)
    }

    func testCannotRemoveLastCategory() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        persistence.save()
        let remaining = ledger.activeCategories
        for category in remaining.dropLast() {
            XCTAssertNil(persistence.removeCategory(category))
        }
        let last = try XCTUnwrap(ledger.activeCategories.first)
        XCTAssertEqual(persistence.removeCategory(last), String(localized: "Keep at least one category.", comment: "Validation"))
        XCTAssertFalse(last.isArchived)
        XCTAssertFalse(last.isDeleted)
    }

    func testCannotRemoveCash() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let cash = try XCTUnwrap(ledger.activePaymentMethods.first { $0.paymentKind == .cash })
        XCTAssertEqual(persistence.removePaymentMethod(cash), String(localized: "Cash can't be removed.", comment: "Validation"))
        XCTAssertFalse(cash.isArchived)
        XCTAssertFalse(cash.isDeleted)
    }

    func testRemoveUnusedPaymentMethodDeletes() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let card = PaymentMethod(context: persistence.viewContext)
        persistence.assign(card, toSameStoreAs: ledger)
        card.name = "Visa"
        card.kind = PaymentKind.creditCard.rawValue
        card.billingCurrency = "HKD"
        card.ledger = ledger
        persistence.save()

        XCTAssertNil(persistence.removePaymentMethod(card))
        let leftover = PaymentMethod.fetchRequest()
        leftover.predicate = NSPredicate(format: "name == %@", "Visa")
        XCTAssertEqual(try persistence.viewContext.count(for: leftover), 0)
    }

    func testRemoveUsedPaymentMethodArchives() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let card = PaymentMethod(context: persistence.viewContext)
        persistence.assign(card, toSameStoreAs: ledger)
        card.name = "Visa"
        card.kind = PaymentKind.creditCard.rawValue
        card.billingCurrency = "HKD"
        card.ledger = ledger
        let expense = Expense(context: persistence.viewContext)
        expense.spendAmount = 10
        expense.chargedAmount = 10
        expense.reportingAmount = 10
        expense.spendCurrency = "HKD"
        expense.chargedCurrency = "HKD"
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = ledger.activeCategories[0]
        expense.paymentMethod = card
        persistence.save()

        XCTAssertNil(persistence.removePaymentMethod(card))
        XCTAssertFalse(card.isDeleted)
        XCTAssertTrue(card.isArchived)
        XCTAssertEqual(expense.paymentMethod, card)
    }

    func testHouseholdIsDistinctFromPersonal() {
        let persistence = Self.stack
        let household = persistence.createLedger(name: "Family", kind: .household, reportingCurrency: "HKD")
        persistence.save()
        XCTAssertTrue(household.isHousehold)
        XCTAssertFalse(household.isPersonal)
        XCTAssertEqual(household.ledgerKind, .household)
        XCTAssertFalse(persistence.cloudKitEnabled)
    }

    func testOptionalReceiptAttachment() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let expense = Expense(context: persistence.viewContext)
        expense.spendAmount = 12
        expense.chargedAmount = 12
        expense.reportingAmount = 12
        expense.spendCurrency = "HKD"
        expense.chargedCurrency = "HKD"
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = ledger.activeCategories[0]
        expense.paymentMethod = ledger.activePaymentMethods[0]
        persistence.save()
        XCTAssertFalse(expense.hasReceipt)

        expense.receiptData = Data("%PDF-1.4".utf8)
        expense.receiptFileName = "lunch.pdf"
        expense.receiptContentType = "com.adobe.pdf"
        persistence.save()

        XCTAssertTrue(expense.hasReceipt)
        XCTAssertEqual(expense.wrappedReceiptFileName, "lunch.pdf")
    }
}
