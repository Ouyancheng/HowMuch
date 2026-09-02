import CloudKit
import CoreData
import XCTest
@testable import HowMuch

@MainActor
final class PersistenceTests: XCTestCase {
    /// Retained for the process lifetime so XCTest's post-test memory checker
    /// does not tear down an in-memory Core Data stack mid-dealloc.
    private static let stack = PersistenceController.makeTestStack()
    private static let dualStack = PersistenceController.makeTestStack(includeSharedStore: true)
    private static let dualSQLiteStack = PersistenceController.makeTestStack(
        storeType: .sqlite,
        includeSharedStore: true
    )

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            let context = Self.stack.viewContext
            context.registeredObjects.forEach(context.delete)
            Self.stack.save()
        }
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

    func testDeleteLedgerRemovesCascadedGraphAndKeepsOnePersonal() throws {
        let persistence = Self.stack
        let keep = persistence.createLedger(name: "Keep", kind: .personal, reportingCurrency: "HKD")
        let remove = persistence.createLedger(name: "Remove", kind: .personal, reportingCurrency: "USD")
        let household = persistence.createLedger(name: "Family", kind: .household, reportingCurrency: "HKD")
        persistence.save()

        let extraExpense = Expense(context: persistence.viewContext)
        extraExpense.spendAmount = 5
        extraExpense.chargedAmount = 5
        extraExpense.reportingAmount = 5
        extraExpense.spendCurrency = "USD"
        extraExpense.chargedCurrency = "USD"
        extraExpense.reportingCurrency = "USD"
        extraExpense.ledger = remove
        extraExpense.category = remove.activeCategories[0]
        extraExpense.paymentMethod = remove.activePaymentMethods[0]
        persistence.save()

        XCTAssertTrue(persistence.canDeleteLedger(keep))
        XCTAssertTrue(persistence.canDeleteLedger(remove))
        XCTAssertTrue(persistence.canDeleteLedger(household))

        let nextID = try persistence.deleteLedger(remove)
        XCTAssertEqual(nextID, keep.uuid)
        XCTAssertEqual(try persistence.viewContext.count(for: Expense.fetchRequest()), 0)
        XCTAssertEqual(try persistence.viewContext.count(for: Ledger.fetchRequest()), 2)
        XCTAssertFalse(persistence.canDeleteLedger(keep))

        XCTAssertThrowsError(try persistence.deleteLedger(keep)) { error in
            XCTAssertEqual(error as? LedgerDeletionError, .lastPersonalLedger)
        }
        XCTAssertEqual(keep.wrappedName, "Keep")

        let leftover = try persistence.deleteLedger(household)
        XCTAssertEqual(leftover, keep.uuid)
        XCTAssertEqual(try persistence.viewContext.count(for: Ledger.fetchRequest()), 1)
    }

    func testSharedAndReadOnlyLedgersCannotBeDeleted() throws {
        let persistence = Self.stack
        persistence.createLedger(name: "Personal", kind: .personal, reportingCurrency: "HKD")
        let family = persistence.createLedger(name: "Family", kind: .household, reportingCurrency: "HKD")
        persistence.save()

        persistence.ledgerAccessResolverForTesting = { _ in .sharedOwner }
        persistence.invalidateLedgerAccess()
        XCTAssertFalse(persistence.canDeleteLedger(family))
        XCTAssertThrowsError(try persistence.deleteLedger(family)) { error in
            XCTAssertEqual(error as? LedgerDeletionError, .stopSharingFirst)
        }

        persistence.ledgerAccessResolverForTesting = { _ in .readWriteParticipant }
        persistence.invalidateLedgerAccess()
        XCTAssertThrowsError(try persistence.deleteLedger(family)) { error in
            XCTAssertEqual(error as? LedgerDeletionError, .leaveSharingFirst)
        }

        persistence.ledgerAccessResolverForTesting = { _ in .readOnlyParticipant }
        persistence.invalidateLedgerAccess()
        XCTAssertThrowsError(try persistence.deleteLedger(family)) { error in
            XCTAssertEqual(error as? LedgerAccessError, .readOnly)
        }

        persistence.ledgerAccessResolverForTesting = nil
        persistence.invalidateLedgerAccess()
        XCTAssertTrue(persistence.canDeleteLedger(family))
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

    func testLedgerAccessSemanticMatrix() {
        XCTAssertEqual(
            LedgerAccess.shared(role: .owner, permission: .readWrite),
            .sharedOwner
        )
        XCTAssertEqual(
            LedgerAccess.shared(role: .owner, permission: .readOnly),
            .sharedOwner
        )
        XCTAssertEqual(
            LedgerAccess.shared(role: .participant, permission: .readWrite),
            .readWriteParticipant
        )
        XCTAssertEqual(
            LedgerAccess.shared(role: .participant, permission: .readOnly),
            .readOnlyParticipant
        )
        XCTAssertEqual(
            LedgerAccess.shared(role: .participant, permission: .unknown),
            .unknown
        )
        XCTAssertEqual(
            LedgerAccess.shared(role: .unknown, permission: .readWrite),
            .unknown
        )

        XCTAssertTrue(LedgerAccess.personalOwner.canWrite)
        XCTAssertTrue(LedgerAccess.unsharedOwner.canWrite)
        XCTAssertTrue(LedgerAccess.sharedOwner.canWrite)
        XCTAssertTrue(LedgerAccess.readWriteParticipant.canWrite)
        XCTAssertFalse(LedgerAccess.readOnlyParticipant.canWrite)
        XCTAssertFalse(LedgerAccess.unknown.canWrite)
        XCTAssertTrue(LedgerAccess.sharedOwner.canManageSharing)
        XCTAssertTrue(LedgerAccess.readOnlyParticipant.canLeaveSharing)
        XCTAssertFalse(LedgerAccess.readWriteParticipant.canManageSharing)
    }

    func testLocalPersonalAndUnsharedHouseholdAreWritable() throws {
        let persistence = Self.stack
        let personal = persistence.createLedger(
            name: "Personal",
            kind: .personal,
            reportingCurrency: "HKD"
        )
        let household = persistence.createLedger(
            name: "Family",
            kind: .household,
            reportingCurrency: "HKD"
        )
        persistence.save()

        XCTAssertEqual(persistence.access(for: personal), .personalOwner)
        XCTAssertEqual(persistence.access(for: household), .unsharedOwner)
        XCTAssertNoThrow(try persistence.assertWritable(personal))
        XCTAssertNoThrow(try persistence.assertWritable(household))
    }

    func testUnknownSharedLedgerMutationFailsClosed() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let sharedStore = try XCTUnwrap(persistence.sharedStore)
        let ledger = makeLedger(named: "Shared", in: sharedStore, context: context)
        let category = makeCategory(named: "Dining", ledger: ledger, in: sharedStore, context: context)
        let method = makeMethod(named: "Cash", ledger: ledger, in: sharedStore, context: context)
        let expense = Expense(context: context)
        context.assign(expense, to: sharedStore)
        expense.ledger = ledger
        expense.category = category
        expense.paymentMethod = method
        try context.save()

        XCTAssertEqual(persistence.access(for: ledger), .unknown)
        XCTAssertThrowsError(try persistence.deleteExpense(expense)) { error in
            XCTAssertEqual(error as? LedgerAccessError, .accessUnavailable)
        }
        XCTAssertFalse(expense.isDeleted)
    }

    func testReadOnlyPolicySeamGuardsChildMutationBeforeEditing() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(
            name: "Shared",
            kind: .household,
            reportingCurrency: "HKD"
        )
        persistence.save()
        let category = try XCTUnwrap(ledger.activeCategories.first)
        let originalName = category.wrappedName

        persistence.ledgerAccessResolverForTesting = { _ in .readOnlyParticipant }
        persistence.invalidateLedgerAccess()
        defer {
            persistence.ledgerAccessResolverForTesting = nil
            persistence.invalidateLedgerAccess()
        }

        XCTAssertThrowsError(
            try persistence.saveCategory(
                category,
                in: ledger,
                name: "Changed",
                symbolName: category.wrappedSymbolName,
                colorHex: category.wrappedColorHex
            )
        ) { error in
            XCTAssertEqual(error as? LedgerAccessError, .readOnly)
        }
        XCTAssertEqual(category.wrappedName, originalName)
    }

    func testMutationRevalidatesCachedSharedWritePermission() throws {
        let persistence = Self.stack
        let ledger = persistence.createLedger(
            name: "Permission changes",
            kind: .household,
            reportingCurrency: "HKD"
        )
        persistence.save()
        var resolutionCount = 0
        persistence.ledgerAccessResolverForTesting = { _ in
            resolutionCount += 1
            return resolutionCount == 1 ? .readWriteParticipant : .readOnlyParticipant
        }
        persistence.invalidateLedgerAccess()
        defer {
            persistence.ledgerAccessResolverForTesting = nil
            persistence.invalidateLedgerAccess()
        }

        XCTAssertEqual(persistence.access(for: ledger), .readWriteParticipant)
        XCTAssertThrowsError(try persistence.assertWritable(ledger)) { error in
            XCTAssertEqual(error as? LedgerAccessError, .readOnly)
        }
        XCTAssertEqual(resolutionCount, 2)
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

    func testLedgerGraphCopyIncludesArchivedObjectsAndReceiptBytes() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let sharedStore = try XCTUnwrap(persistence.sharedStore)
        let privateStore = try XCTUnwrap(persistence.privateStore)

        let source = Ledger(context: context)
        context.assign(source, to: sharedStore)
        source.name = "Shared household"
        source.kind = LedgerKind.household.rawValue
        source.reportingCurrency = "HKD"
        source.createdAt = Date(timeIntervalSince1970: 100)
        source.updatedAt = Date(timeIntervalSince1970: 200)

        let category = Category(context: context)
        context.assign(category, to: sharedStore)
        category.name = "Archived dining"
        category.symbolName = "fork.knife"
        category.colorHex = "ABCDEF"
        category.sortOrder = 7
        category.isArchived = true
        category.createdAt = Date(timeIntervalSince1970: 110)

        let method = PaymentMethod(context: context)
        context.assign(method, to: sharedStore)
        method.name = "Old card"
        method.kind = PaymentKind.creditCard.rawValue
        method.billingCurrency = "USD"
        method.isArchived = true
        method.createdAt = Date(timeIntervalSince1970: 120)

        let receiptBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        let expense = Expense(context: context)
        context.assign(expense, to: sharedStore)
        expense.merchant = "Dinner"
        expense.note = "Attribution and receipt"
        expense.occurredAt = Date(timeIntervalSince1970: 130)
        expense.spendAmount = 88
        expense.spendCurrency = "CNY"
        expense.chargedAmount = 96
        expense.chargedCurrency = "HKD"
        expense.reportingAmount = 96
        expense.reportingCurrency = "HKD"
        expense.createdAt = Date(timeIntervalSince1970: 140)
        expense.updatedAt = Date(timeIntervalSince1970: 150)
        expense.createdByName = "Taylor"
        expense.receiptData = receiptBytes
        expense.receiptFileName = "dinner.pdf"
        expense.receiptContentType = "com.adobe.pdf"

        category.ledger = source
        method.ledger = source
        expense.ledger = source
        expense.category = category
        expense.paymentMethod = method
        try context.save()

        let copied = LedgerGraphCopier(context: context).copy(source, to: privateStore)
        try context.save()

        XCTAssertEqual(copied.name, source.name)
        XCTAssertEqual(copied.kind, source.kind)
        XCTAssertEqual(copied.reportingCurrency, source.reportingCurrency)
        XCTAssertEqual(copied.createdAt, source.createdAt)
        XCTAssertEqual(copied.updatedAt, source.updatedAt)
        XCTAssertNotEqual(copied.uuid, source.uuid)
        XCTAssertTrue(copied.objectID.persistentStore === privateStore)

        let copiedCategory = try XCTUnwrap(copied.categories?.first)
        XCTAssertTrue(copiedCategory.isArchived)
        XCTAssertEqual(copiedCategory.name, category.name)
        XCTAssertEqual(copiedCategory.sortOrder, category.sortOrder)
        XCTAssertNotEqual(copiedCategory.uuid, category.uuid)
        XCTAssertTrue(copiedCategory.objectID.persistentStore === privateStore)

        let copiedMethod = try XCTUnwrap(copied.paymentMethods?.first)
        XCTAssertTrue(copiedMethod.isArchived)
        XCTAssertEqual(copiedMethod.billingCurrency, method.billingCurrency)
        XCTAssertNotEqual(copiedMethod.uuid, method.uuid)
        XCTAssertTrue(copiedMethod.objectID.persistentStore === privateStore)

        let copiedExpense = try XCTUnwrap(copied.expenses?.first)
        XCTAssertEqual(copiedExpense.createdByName, "Taylor")
        XCTAssertEqual(copiedExpense.receiptData, receiptBytes)
        XCTAssertEqual(copiedExpense.receiptFileName, "dinner.pdf")
        XCTAssertEqual(copiedExpense.receiptContentType, "com.adobe.pdf")
        XCTAssertNotEqual(copiedExpense.uuid, expense.uuid)
        XCTAssertEqual(copiedExpense.category, copiedCategory)
        XCTAssertEqual(copiedExpense.paymentMethod, copiedMethod)
        XCTAssertEqual(copiedExpense.ledger, copied)
        XCTAssertTrue(copiedExpense.objectID.persistentStore === privateStore)
    }

    func testExpenseTransferAcrossStoresPreservesUUIDAndUsesDestinationGraph() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let sharedStore = try XCTUnwrap(persistence.sharedStore)
        let privateStore = try XCTUnwrap(persistence.privateStore)

        let sourceLedger = makeLedger(named: "Shared", in: sharedStore, context: context)
        let sourceCategory = makeCategory(named: "Source", ledger: sourceLedger, in: sharedStore, context: context)
        let sourceMethod = makeMethod(named: "Source card", ledger: sourceLedger, in: sharedStore, context: context)
        let source = Expense(context: context)
        context.assign(source, to: sharedStore)
        source.uuid = UUID()
        let originalUUID = source.uuid
        source.createdAt = Date(timeIntervalSince1970: 300)
        source.createdByName = "Morgan"
        source.ledger = sourceLedger
        source.category = sourceCategory
        source.paymentMethod = sourceMethod

        let destinationLedger = makeLedger(named: "Private", in: privateStore, context: context)
        let destinationCategory = makeCategory(named: "Destination", ledger: destinationLedger, in: privateStore, context: context)
        let destinationMethod = makeMethod(named: "Destination cash", ledger: destinationLedger, in: privateStore, context: context)
        try context.save()
        let sourceID = source.objectID

        persistence.ledgerAccessResolverForTesting = { ledger in
            ledger.objectID == sourceLedger.objectID ? .readWriteParticipant : .unsharedOwner
        }
        persistence.invalidateLedgerAccess()
        defer {
            persistence.ledgerAccessResolverForTesting = nil
            persistence.invalidateLedgerAccess()
        }

        let moved = try persistence.saveExpense(
            source,
            to: destinationLedger,
            category: destinationCategory,
            paymentMethod: destinationMethod,
            values: ExpenseEditValues(
                merchant: "Edited",
                note: "Moved safely",
                occurredAt: Date(timeIntervalSince1970: 400),
                spendAmount: 20,
                spendCurrency: "USD",
                chargedAmount: 156,
                chargedCurrency: "HKD",
                reportingAmount: 156,
                reportingCurrency: "HKD",
                receiptData: Data([1, 2, 3]),
                receiptFileName: "receipt.jpg",
                receiptContentType: "public.jpeg"
            )
        )

        XCTAssertEqual(moved.uuid, originalUUID)
        XCTAssertEqual(moved.createdAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(moved.createdByName, "Morgan")
        XCTAssertEqual(moved.merchant, "Edited")
        XCTAssertEqual(moved.receiptData, Data([1, 2, 3]))
        XCTAssertEqual(moved.ledger, destinationLedger)
        XCTAssertEqual(moved.category, destinationCategory)
        XCTAssertEqual(moved.paymentMethod, destinationMethod)
        XCTAssertTrue(moved.objectID.persistentStore === privateStore)
        XCTAssertThrowsError(try context.existingObject(with: sourceID))

        let request = Expense.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", try XCTUnwrap(originalUUID) as CVarArg)
        XCTAssertEqual(try context.count(for: request), 1)
    }

    func testExpenseTransferJournalRecoversEveryDurablePhaseWithoutDuplicates() throws {
        for failurePoint in [
            ExpenseTransferFailurePoint.afterJournal,
            .afterDestinationSave,
            .afterSourceDelete
        ] {
            let persistence = Self.dualSQLiteStack
            try clear(persistence)
            let context = persistence.viewContext
            let sharedStore = try XCTUnwrap(persistence.sharedStore)
            let privateStore = try XCTUnwrap(persistence.privateStore)
            let sourceLedger = makeLedger(
                named: "Source \(failurePoint)",
                in: sharedStore,
                context: context
            )
            let sourceCategory = makeCategory(
                named: "Source",
                ledger: sourceLedger,
                in: sharedStore,
                context: context
            )
            let sourceMethod = makeMethod(
                named: "Source",
                ledger: sourceLedger,
                in: sharedStore,
                context: context
            )
            let source = Expense(context: context)
            context.assign(source, to: sharedStore)
            let expenseUUID = try XCTUnwrap(source.uuid)
            source.ledger = sourceLedger
            source.category = sourceCategory
            source.paymentMethod = sourceMethod

            let destinationLedger = makeLedger(
                named: "Destination",
                in: privateStore,
                context: context
            )
            let destinationCategory = makeCategory(
                named: "Destination",
                ledger: destinationLedger,
                in: privateStore,
                context: context
            )
            let destinationMethod = makeMethod(
                named: "Destination",
                ledger: destinationLedger,
                in: privateStore,
                context: context
            )
            try context.save()

            let suiteName = "HowMuchTests.ExpenseTransfer.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let journal = ExpenseTransferJournalStore(defaults: defaults, key: "journal")
            persistence.expenseTransferJournalStore = journal
            persistence.ledgerAccessResolverForTesting = { ledger in
                ledger.objectID == sourceLedger.objectID ? .readWriteParticipant : .unsharedOwner
            }
            persistence.invalidateLedgerAccess()
            persistence.expenseTransferFailureInjector = { point in
                if point == failurePoint {
                    throw CocoaError(.persistentStoreOperation)
                }
            }

            XCTAssertThrowsError(
                try persistence.saveExpense(
                    source,
                    to: destinationLedger,
                    category: destinationCategory,
                    paymentMethod: destinationMethod,
                    values: ExpenseEditValues(
                        merchant: "Recovered",
                        note: "Two phase",
                        occurredAt: Date(timeIntervalSince1970: 500),
                        spendAmount: 8,
                        spendCurrency: "USD",
                        chargedAmount: 8,
                        chargedCurrency: "USD",
                        reportingAmount: 8,
                        reportingCurrency: "USD",
                        receiptData: nil,
                        receiptFileName: nil,
                        receiptContentType: nil
                    )
                )
            )
            XCTAssertEqual(journal.records(accountFingerprint: "test").count, 1)

            persistence.expenseTransferFailureInjector = nil
            persistence.recoverPendingExpenseTransfers()

            let matches = Expense.fetchRequest()
            matches.predicate = NSPredicate(format: "uuid == %@", expenseUUID as CVarArg)
            let recovered = try context.fetch(matches)
            XCTAssertEqual(recovered.count, 1, "Failure point: \(failurePoint)")
            XCTAssertEqual(recovered.first?.ledger?.objectID, destinationLedger.objectID)
            XCTAssertEqual(recovered.first?.merchant, "Recovered")
            XCTAssertEqual(journal.records(accountFingerprint: "test").count, 0)

            persistence.ledgerAccessResolverForTesting = nil
            persistence.invalidateLedgerAccess()
        }
    }

    func testCrossLedgerTransferWithinSharedStoreUsesDurableJournal() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let sharedStore = try XCTUnwrap(persistence.sharedStore)
        let sourceLedger = makeLedger(named: "Zone A", in: sharedStore, context: context)
        let sourceCategory = makeCategory(
            named: "Source",
            ledger: sourceLedger,
            in: sharedStore,
            context: context
        )
        let sourceMethod = makeMethod(
            named: "Source",
            ledger: sourceLedger,
            in: sharedStore,
            context: context
        )
        let destinationLedger = makeLedger(named: "Zone B", in: sharedStore, context: context)
        let destinationCategory = makeCategory(
            named: "Destination",
            ledger: destinationLedger,
            in: sharedStore,
            context: context
        )
        let destinationMethod = makeMethod(
            named: "Destination",
            ledger: destinationLedger,
            in: sharedStore,
            context: context
        )
        let source = Expense(context: context)
        context.assign(source, to: sharedStore)
        source.ledger = sourceLedger
        source.category = sourceCategory
        source.paymentMethod = sourceMethod
        let expenseUUID = try XCTUnwrap(source.uuid)
        try context.save()

        let suiteName = "HowMuchTests.CrossZoneTransfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let journal = ExpenseTransferJournalStore(defaults: defaults, key: "journal")
        persistence.expenseTransferJournalStore = journal
        persistence.ledgerAccessResolverForTesting = { _ in .readWriteParticipant }
        persistence.invalidateLedgerAccess()
        defer {
            persistence.ledgerAccessResolverForTesting = nil
            persistence.invalidateLedgerAccess()
        }

        let moved = try persistence.saveExpense(
            source,
            to: destinationLedger,
            category: destinationCategory,
            paymentMethod: destinationMethod,
            values: ExpenseEditValues(
                merchant: "Cross-zone",
                note: "",
                occurredAt: Date(timeIntervalSince1970: 600),
                spendAmount: 1,
                spendCurrency: "USD",
                chargedAmount: 1,
                chargedCurrency: "USD",
                reportingAmount: 1,
                reportingCurrency: "USD",
                receiptData: nil,
                receiptFileName: nil,
                receiptContentType: nil
            )
        )

        XCTAssertEqual(moved.uuid, expenseUUID)
        XCTAssertEqual(moved.ledger?.objectID, destinationLedger.objectID)
        XCTAssertTrue(moved.objectID.persistentStore === sharedStore)
        XCTAssertEqual(journal.records(accountFingerprint: "test").count, 0)
    }

    func testSystemStopOwnerPreparationCreatesExactlyOneDurableRetainedCopy() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let privateStore = try XCTUnwrap(persistence.privateStore)
        let source = makeLedger(
            named: "System-managed share",
            in: privateStore,
            context: context
        )
        _ = makeCategory(
            named: "Dining",
            ledger: source,
            in: privateStore,
            context: context
        )
        _ = makeMethod(
            named: "Cash",
            ledger: source,
            in: privateStore,
            context: context
        )
        try context.save()

        let suiteName = "HowMuchTests.SystemStop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let retryStore = StopSharingRetryStore(defaults: defaults, key: "system-stop")
        let zoneID = CKRecordZone.ID(zoneName: "known-zone", ownerName: "known-owner")
        let fingerprint = CloudIdentityFingerprint.make(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "owner-account"
        )

        _ = try persistence.prepareSystemStopRetry(
            for: source,
            role: .owner,
            zoneID: zoneID,
            accountRecordName: "owner-account",
            accountFingerprint: fingerprint,
            retryStore: retryStore
        )

        let originalURI = source.objectID.uriRepresentation().absoluteString
        guard case .found(let durable) = retryStore.lookup(
            originalLedgerUUID: try XCTUnwrap(source.uuid),
            originalObjectURI: originalURI
        ) else {
            return XCTFail("Expected a durable completed system-stop record")
        }
        let retainedUUID = try XCTUnwrap(durable.retainedLedgerUUID)
        XCTAssertNotNil(durable.retainedObjectURI)

        persistence.pendingStopSharingRetries.removeAll()
        _ = try persistence.prepareSystemStopRetry(
            for: source,
            role: .owner,
            zoneID: zoneID,
            accountRecordName: "owner-account",
            accountFingerprint: fingerprint,
            retryStore: retryStore
        )

        let retainedRequest = Ledger.fetchRequest()
        retainedRequest.predicate = NSPredicate(
            format: "uuid == %@",
            retainedUUID as CVarArg
        )
        let retained = try context.fetch(retainedRequest)
        XCTAssertEqual(retained.count, 1)
        XCTAssertNotEqual(retained.first?.objectID, source.objectID)
        XCTAssertEqual(retained.first?.categories?.count, 1)
        XCTAssertEqual(retained.first?.paymentMethods?.count, 1)
    }

    func testSystemStopParticipantPreparationNeverCreatesPrivateCopy() throws {
        let persistence = Self.dualStack
        try clear(persistence)
        let context = persistence.viewContext
        let sharedStore = try XCTUnwrap(persistence.sharedStore)
        let source = makeLedger(
            named: "Participant share",
            in: sharedStore,
            context: context
        )
        try context.save()

        let suiteName = "HowMuchTests.SystemStopParticipant.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let retryStore = StopSharingRetryStore(defaults: defaults, key: "system-stop")
        let fingerprint = CloudIdentityFingerprint.make(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "participant-account"
        )
        _ = try persistence.prepareSystemStopRetry(
            for: source,
            role: .participant,
            zoneID: CKRecordZone.ID(zoneName: "shared-zone", ownerName: "owner"),
            accountRecordName: "participant-account",
            accountFingerprint: fingerprint,
            retryStore: retryStore
        )

        let ledgers = try context.fetch(Ledger.fetchRequest())
        XCTAssertEqual(ledgers.map(\.objectID), [source.objectID])
        guard case .found(let durable) = retryStore.lookup(
            originalLedgerUUID: try XCTUnwrap(source.uuid),
            originalObjectURI: source.objectID.uriRepresentation().absoluteString
        ) else {
            return XCTFail("Expected durable participant purge state")
        }
        XCTAssertNil(durable.retainedLedgerUUID)
        XCTAssertNil(durable.retainedObjectURI)
    }

    func testStopSharingRetryStateRestoresIdempotentlyAndRejectsStaleIdentity() throws {
        let suiteName = "HowMuchTests.StopSharingRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = StopSharingRetryStore(defaults: defaults, key: "retry")
        let originalUUID = UUID()
        let retainedUUID = UUID()
        let accountFingerprint = CloudIdentityFingerprint.make(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "current-account"
        )
        let record = DurableStopSharingRetry(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "current-account",
            originalLedgerUUID: originalUUID,
            originalObjectURI: "x-coredata://store/Ledger/original",
            retainedLedgerUUID: retainedUUID,
            retainedObjectURI: "x-coredata://store/Ledger/retained",
            zoneName: "shared-zone",
            zoneOwnerName: "zone-owner",
            role: .owner,
            accountFingerprint: accountFingerprint
        )

        XCTAssertTrue(store.save(record))
        XCTAssertTrue(store.save(record))

        let restoredStore = StopSharingRetryStore(defaults: defaults, key: "retry")
        guard case .found(let restored) = restoredStore.lookup(
            originalLedgerUUID: originalUUID,
            originalObjectURI: record.originalObjectURI
        ) else {
            return XCTFail("Expected durable retry state to restore")
        }
        XCTAssertEqual(restored, record)
        XCTAssertTrue(restored.matches(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "current-account",
            accountFingerprint: accountFingerprint,
            originalLedgerUUID: originalUUID,
            originalObjectURI: record.originalObjectURI,
            zoneName: "shared-zone",
            zoneOwnerName: "zone-owner",
            role: .owner
        ))
        XCTAssertFalse(restored.matches(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: "different-account",
            accountFingerprint: CloudIdentityFingerprint.make(
                containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
                accountRecordName: "different-account"
            ),
            originalLedgerUUID: originalUUID,
            originalObjectURI: record.originalObjectURI,
            zoneName: "shared-zone",
            zoneOwnerName: "zone-owner",
            role: .owner
        ))

        if case .unsafe = restoredStore.lookup(
            originalLedgerUUID: originalUUID,
            originalObjectURI: "x-coredata://different/Ledger/original"
        ) {
            // Expected: a known UUID at another URI must never be reused.
        } else {
            XCTFail("Expected stale object URI to be rejected")
        }

        XCTAssertTrue(restoredStore.remove(
            originalLedgerUUID: originalUUID,
            originalObjectURI: record.originalObjectURI
        ))
        if case .missing = restoredStore.lookup(
            originalLedgerUUID: originalUUID,
            originalObjectURI: record.originalObjectURI
        ) {
            // Expected.
        } else {
            XCTFail("Expected retry state to be cleared")
        }
    }

    func testDualSQLiteTestStackLoadsPrivateAndSharedStores() throws {
        let persistence = Self.dualSQLiteStack
        XCTAssertNotNil(persistence.privateStore)
        XCTAssertNotNil(persistence.sharedStore)
        XCTAssertFalse(persistence.privateStore === persistence.sharedStore)
    }

    func testCloudIdentityFingerprintIsStableAndAccountSpecific() {
        let first = CloudIdentityFingerprint.make(
            containerIdentifier: "iCloud.example",
            accountRecordName: "account-a"
        )
        let repeated = CloudIdentityFingerprint.make(
            containerIdentifier: "iCloud.example",
            accountRecordName: "account-a"
        )
        let replacement = CloudIdentityFingerprint.make(
            containerIdentifier: "iCloud.example",
            accountRecordName: "account-b"
        )

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, replacement)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testScopedStoreLocationsSeparateAccounts() {
        let base = URL(fileURLWithPath: "/tmp/HowMuchScope", isDirectory: true)
        let first = CloudStoreScope.locations(baseDirectory: base, fingerprint: "first")
        let second = CloudStoreScope.locations(baseDirectory: base, fingerprint: "second")

        XCTAssertEqual(first.privateStore.lastPathComponent, "private.sqlite")
        XCTAssertEqual(first.sharedStore.lastPathComponent, "shared.sqlite")
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertTrue(first.privateStore.path.contains("/Accounts/first/"))
        XCTAssertTrue(second.sharedStore.path.contains("/Accounts/second/"))
    }

    func testLegacyPrivateStoreIsClaimedByOneAccountAndSharedStoreIsPreserved() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchAdoption-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacyPrivate = base.appendingPathComponent("private.sqlite")
        let legacyPrivateWAL = URL(fileURLWithPath: legacyPrivate.path + "-wal")
        let legacyShared = base.appendingPathComponent("shared.sqlite")
        try Data("private-main".utf8).write(to: legacyPrivate)
        try Data("private-wal".utf8).write(to: legacyPrivateWAL)
        try Data("shared-main".utf8).write(to: legacyShared)

        let oldAccountDirectory = base
            .appendingPathComponent(CloudStoreScope.accountsDirectoryName, isDirectory: true)
            .appendingPathComponent("old-account", isDirectory: true)
        try fileManager.createDirectory(at: oldAccountDirectory, withIntermediateDirectories: true)
        let oldSentinel = oldAccountDirectory.appendingPathComponent("private.sqlite")
        try Data("old-account-data".utf8).write(to: oldSentinel)

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "current-account",
            fileManager: fileManager
        )

        let locations = CloudStoreScope.locations(
            baseDirectory: base,
            fingerprint: "current-account"
        )
        XCTAssertEqual(try Data(contentsOf: locations.privateStore), Data("private-main".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: locations.privateStore.path + "-wal")),
            Data("private-wal".utf8)
        )
        XCTAssertFalse(fileManager.fileExists(atPath: locations.sharedStore.path))
        XCTAssertEqual(try Data(contentsOf: legacyPrivate), Data("private-main".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyPrivateWAL), Data("private-wal".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyShared), Data("shared-main".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: locations.adoptionMarker.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: base.appendingPathComponent(CloudStoreScope.baseAdoptionClaimName).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: oldSentinel), Data("old-account-data".utf8))

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "current-account",
            fileManager: fileManager
        )
        XCTAssertEqual(try Data(contentsOf: locations.privateStore), Data("private-main".utf8))

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "account-b",
            fileManager: fileManager
        )
        let accountB = CloudStoreScope.locations(baseDirectory: base, fingerprint: "account-b")
        XCTAssertFalse(fileManager.fileExists(atPath: accountB.privateStore.path))
        XCTAssertFalse(fileManager.fileExists(atPath: accountB.sharedStore.path))
        XCTAssertTrue(fileManager.fileExists(atPath: accountB.adoptionMarker.path))
        XCTAssertEqual(try Data(contentsOf: legacyShared), Data("shared-main".utf8))
    }

    func testLocalNoEntitlementModeMountsOnlyPrivateStoreAndBootstraps() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchLocalMode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }

        let persistence = PersistenceController.makeLocalTestStack(
            applicationSupportDirectory: base
        )

        XCTAssertTrue(persistence.isLocalOnly)
        XCTAssertFalse(persistence.cloudKitEnabled)
        XCTAssertEqual(persistence.loadState, .loaded)
        XCTAssertNotNil(persistence.privateStore)
        XCTAssertNil(persistence.sharedStore)
        XCTAssertEqual(
            persistence.privateStore?.url,
            CloudStoreScope.localLocations(baseDirectory: base).privateStore
        )

        let request = Ledger.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
        XCTAssertEqual(try persistence.viewContext.count(for: request), 1)
    }

    func testCloudKitCapableBuildStaysUsableWithoutSignedInAccount() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchOfflineLocal-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }

        let persistence = PersistenceController.makeCloudKitCapableTestStack(
            applicationSupportDirectory: base
        )

        XCTAssertTrue(persistence.isDataAvailable)
        XCTAssertTrue(persistence.isLocalOnly)
        XCTAssertFalse(persistence.cloudKitEnabled)
        XCTAssertFalse(persistence.container is NSPersistentCloudKitContainer)
        XCTAssertNil(persistence.sharedStore)
        XCTAssertEqual(
            persistence.privateStore?.url,
            CloudStoreScope.localLocations(baseDirectory: base).privateStore
        )
        XCTAssertEqual(try persistence.viewContext.count(for: Ledger.fetchRequest()), 1)

        await persistence.applyAccountIdentity(.resolving)
        XCTAssertTrue(persistence.isDataAvailable)
        XCTAssertFalse(persistence.cloudKitEnabled)

        await persistence.applyAccountIdentity(.signedOut)
        XCTAssertTrue(persistence.isDataAvailable)
        XCTAssertTrue(persistence.isLocalOnly)
        XCTAssertFalse(persistence.cloudKitEnabled)
        XCTAssertEqual(try persistence.viewContext.count(for: Ledger.fetchRequest()), 1)

        await persistence.applyAccountIdentity(.unavailable("restricted"))
        XCTAssertTrue(persistence.isDataAvailable)
        XCTAssertFalse(persistence.cloudKitEnabled)
        XCTAssertFalse(persistence.container is NSPersistentCloudKitContainer)
        let ledger = try XCTUnwrap(try persistence.viewContext.fetch(Ledger.fetchRequest()).first)
        _ = try persistence.saveExpense(
            nil,
            to: ledger,
            category: ledger.activeCategories[0],
            paymentMethod: ledger.activePaymentMethods[0],
            values: ExpenseEditValues(
                merchant: "Cafe",
                note: "",
                occurredAt: Date(),
                spendAmount: 4,
                spendCurrency: "USD",
                chargedAmount: 4,
                chargedCurrency: "USD",
                reportingAmount: 4,
                reportingCurrency: "USD",
                receiptData: nil,
                receiptFileName: nil,
                receiptContentType: nil
            )
        )
    }

    func testEnsureWritableStoreLocationClearsImmutableFlag() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchWritableStore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = directory.appendingPathComponent("private.sqlite")
        try Data("store".utf8).write(to: store)
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: store.path)
        let supportBlob = URL(fileURLWithPath: store.path + "_SUPPORT/_EXTERNAL_DATA/blob")
        try fileManager.createDirectory(
            at: supportBlob.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("blob".utf8).write(to: supportBlob)
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: supportBlob.path)
        try fileManager.setAttributes(
            [.immutable: true],
            ofItemAtPath: supportBlob.deletingLastPathComponent().path
        )

        try CloudStoreScope.ensureWritableStoreLocation(store, fileManager: fileManager)

        let attributes = try fileManager.attributesOfItem(atPath: store.path)
        XCTAssertEqual(attributes[.immutable] as? Bool, false)
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: supportBlob.path)[.immutable] as? Bool,
            false
        )
        try Data("rewritten".utf8).write(to: store, options: .atomic)
        try Data("updated".utf8).write(to: supportBlob, options: .atomic)
    }

    func testEnsureWritableStoreLocationRecreatesFilesThatCannotBeOpenedForUpdate() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchRewriteStore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = directory.appendingPathComponent("private.sqlite")
        try Data("store".utf8).write(to: store)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: store.path)
        XCTAssertFalse(CloudStoreScope.canOpenForUpdating(store))

        try CloudStoreScope.ensureWritableStoreLocation(store, fileManager: fileManager)

        XCTAssertTrue(CloudStoreScope.canOpenForUpdating(store))
        let handle = try FileHandle(forUpdating: store)
        try handle.close()
        try Data("rewritten".utf8).write(to: store, options: .atomic)
    }

    func testDiskLocalStoreCanSaveExpenseWithExternalReceipt() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchReceiptWrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }

        let persistence = PersistenceController.makeLocalTestStack(
            applicationSupportDirectory: base
        )
        let ledger = try XCTUnwrap(try persistence.viewContext.fetch(Ledger.fetchRequest()).first)
        let receipt = Data(repeating: 0xAB, count: 1_500_000)
        let expense = try persistence.saveExpense(
            nil,
            to: ledger,
            category: ledger.activeCategories[0],
            paymentMethod: ledger.activePaymentMethods[0],
            values: ExpenseEditValues(
                merchant: "Market",
                note: "",
                occurredAt: Date(),
                spendAmount: 10,
                spendCurrency: "USD",
                chargedAmount: 10,
                chargedCurrency: "USD",
                reportingAmount: 10,
                reportingCurrency: "USD",
                receiptData: receipt,
                receiptFileName: "receipt.jpg",
                receiptContentType: "public.jpeg"
            )
        )
        XCTAssertEqual(expense.receiptData?.count, receipt.count)
    }

    func testLocalStoreRemainsWritableAfterItWasOpenedWithHistoryTracking() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchHistoryReadonly-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let storeURL = CloudStoreScope.localLocations(baseDirectory: base).privateStore
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priming = NSPersistentContainer(
            name: "HowMuch",
            managedObjectModel: PersistenceController.managedObjectModel
        )
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        priming.persistentStoreDescriptions = [description]
        priming.loadPersistentStores { _, error in
            XCTAssertNil(error)
        }
        try priming.persistentStoreCoordinator.remove(priming.persistentStoreCoordinator.persistentStores[0])

        try Data().write(
            to: CloudStoreScope.localLocations(baseDirectory: base).adoptionMarker,
            options: .atomic
        )

        let persistence = PersistenceController.makeLocalTestStack(
            applicationSupportDirectory: base
        )
        let ledger = try XCTUnwrap(try persistence.viewContext.fetch(Ledger.fetchRequest()).first)
        _ = try persistence.saveExpense(
            nil,
            to: ledger,
            category: ledger.activeCategories[0],
            paymentMethod: ledger.activePaymentMethods[0],
            values: ExpenseEditValues(
                merchant: "History",
                note: "",
                occurredAt: Date(),
                spendAmount: 3,
                spendCurrency: "USD",
                chargedAmount: 3,
                chargedCurrency: "USD",
                reportingAmount: 3,
                reportingCurrency: "USD",
                receiptData: nil,
                receiptFileName: nil,
                receiptContentType: nil
            )
        )
    }

    func testLocalPrivateStoreIsCopiedIntoVerifiedAccountWithoutDeletingSources() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchLocalUpgrade-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacyPrivate = base.appendingPathComponent("private.sqlite")
        let legacyShared = base.appendingPathComponent("shared.sqlite")
        try Data("private".utf8).write(to: legacyPrivate)
        try Data("shared".utf8).write(to: legacyShared)

        let local = try CloudStoreScope.prepareLocalStoreIfNeeded(
            baseDirectory: base,
            fileManager: fileManager
        )
        XCTAssertEqual(try Data(contentsOf: local.privateStore), Data("private".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyPrivate), Data("private".utf8))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: CloudStoreScope.supportDirectory(for: local.privateStore)
                    .appendingPathComponent("_EXTERNAL_DATA").path
            )
        )

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "verified-account",
            fileManager: fileManager
        )
        let scoped = CloudStoreScope.locations(
            baseDirectory: base,
            fingerprint: "verified-account"
        )
        XCTAssertEqual(try Data(contentsOf: scoped.privateStore), Data("private".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: scoped.sharedStore.path))
        XCTAssertEqual(try Data(contentsOf: local.privateStore), Data("private".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyPrivate), Data("private".utf8))
        XCTAssertEqual(try Data(contentsOf: legacyShared), Data("shared".utf8))
    }

    func testAdoptionCopiesExternalBinarySupportDirectory() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchSupportAdopt-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacyPrivate = base.appendingPathComponent("private.sqlite")
        try Data("private".utf8).write(to: legacyPrivate)
        let legacyBlob = CloudStoreScope.supportDirectory(for: legacyPrivate)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("receipt.bin")
        try fileManager.createDirectory(
            at: legacyBlob.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("receipt-bytes".utf8).write(to: legacyBlob)
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: legacyBlob.path)

        let local = try CloudStoreScope.prepareLocalStoreIfNeeded(
            baseDirectory: base,
            fileManager: fileManager
        )
        let localBlob = CloudStoreScope.supportDirectory(for: local.privateStore)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("receipt.bin")
        XCTAssertEqual(try Data(contentsOf: localBlob), Data("receipt-bytes".utf8))
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: localBlob.path)[.immutable] as? Bool,
            false
        )

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "verified-account",
            fileManager: fileManager
        )
        let scoped = CloudStoreScope.locations(
            baseDirectory: base,
            fingerprint: "verified-account"
        )
        let scopedBlob = CloudStoreScope.supportDirectory(for: scoped.privateStore)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("receipt.bin")
        XCTAssertEqual(try Data(contentsOf: scopedBlob), Data("receipt-bytes".utf8))
        try Data("rewritten-receipt".utf8).write(to: scopedBlob, options: .atomic)
    }

    func testRepairExternalBinaryStorageCopiesLegacyHiddenSupportFiles() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchHiddenSupport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacyPrivate = base.appendingPathComponent("private.sqlite")
        try Data("private".utf8).write(to: legacyPrivate)
        let hiddenBlob = base
            .appendingPathComponent(".private_SUPPORT", isDirectory: true)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("C37E6413-0668-4366-BBBF-6E1B7A457134")
        try fileManager.createDirectory(
            at: hiddenBlob.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("receipt-bytes".utf8).write(to: hiddenBlob)

        let local = try CloudStoreScope.prepareLocalStoreIfNeeded(
            baseDirectory: base,
            fileManager: fileManager
        )
        let repaired = CloudStoreScope.supportDirectory(for: local.privateStore)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
            .appendingPathComponent("C37E6413-0668-4366-BBBF-6E1B7A457134")
        XCTAssertEqual(try Data(contentsOf: repaired), Data("receipt-bytes".utf8))
    }

    func testAdoptionRewritesReadOnlySQLiteCopies() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchReadOnlyAdopt-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacyPrivate = base.appendingPathComponent("private.sqlite")
        try Data("private".utf8).write(to: legacyPrivate)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: legacyPrivate.path)

        let local = try CloudStoreScope.prepareLocalStoreIfNeeded(
            baseDirectory: base,
            fileManager: fileManager
        )
        XCTAssertTrue(fileManager.isWritableFile(atPath: local.privateStore.path))
        try Data("rewritten".utf8).write(to: local.privateStore, options: .atomic)
    }

    func testCloudKitDefaultDirectoryUsesHowMuchSupportFolder() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchDefaultDir-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        _ = PersistenceController.makeLocalTestStack(applicationSupportDirectory: base)
        XCTAssertEqual(
            HowMuchPersistentContainer.defaultDirectoryURL().standardizedFileURL,
            base.standardizedFileURL
        )
    }

    func testAdoptionConflictPreservesBothStoreCopies() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchAdoptionConflict-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacy = base.appendingPathComponent("private.sqlite")
        try Data("legacy".utf8).write(to: legacy)
        let locations = CloudStoreScope.locations(baseDirectory: base, fingerprint: "account")
        try fileManager.createDirectory(at: locations.directory, withIntermediateDirectories: true)
        try Data("scoped".utf8).write(to: locations.privateStore)

        XCTAssertThrowsError(
            try CloudStoreScope.adoptUnscopedStoresIfNeeded(
                baseDirectory: base,
                fingerprint: "account",
                fileManager: fileManager
            )
        )
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy".utf8))
        XCTAssertEqual(try Data(contentsOf: locations.privateStore), Data("scoped".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: locations.adoptionMarker.path))
    }

    func testInterruptedClaimedAdoptionRepairsPartialDestinationFromRetainedSource() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HowMuchAdoptionRepair-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let legacy = base.appendingPathComponent("private.sqlite")
        try Data("complete-source".utf8).write(to: legacy)
        let locations = CloudStoreScope.locations(baseDirectory: base, fingerprint: "account")
        try fileManager.createDirectory(at: locations.directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"accountFingerprint":"account"}"#.utf8).write(
            to: base.appendingPathComponent(CloudStoreScope.baseAdoptionClaimName),
            options: .atomic
        )
        try Data().write(
            to: locations.directory.appendingPathComponent(CloudStoreScope.adoptionIntentName),
            options: .atomic
        )
        try Data("partial".utf8).write(to: locations.privateStore)

        try CloudStoreScope.adoptUnscopedStoresIfNeeded(
            baseDirectory: base,
            fingerprint: "account",
            fileManager: fileManager
        )

        XCTAssertEqual(try Data(contentsOf: locations.privateStore), Data("complete-source".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("complete-source".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: locations.adoptionMarker.path))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: locations.directory.appendingPathComponent(
                    CloudStoreScope.adoptionIntentName
                ).path
            )
        )
    }

    func testStackGenerationResetClearsSelectionAndPresentations() {
        let appState = AppState()
        appState.selectedLedgerID = UUID()
        appState.presentingNewExpense = true
        appState.presentingNewPersonal = true
        appState.presentingNewHousehold = true
        appState.presentingLedgerSettings = true
        appState.expenseToEdit = Expense(context: Self.stack.viewContext)

        appState.resetForStackGeneration(1)

        XCTAssertNil(appState.selectedLedgerID)
        XCTAssertFalse(appState.presentingNewExpense)
        XCTAssertFalse(appState.presentingNewPersonal)
        XCTAssertFalse(appState.presentingNewHousehold)
        XCTAssertFalse(appState.presentingLedgerSettings)
        XCTAssertNil(appState.expenseToEdit)
        XCTAssertEqual(appState.observedStackGeneration, 1)
    }

    func testHistoryTokensAreSeparatedByAccountAndStoreRole() {
        let privateA = PersistenceController.historyTokenKey(
            fingerprint: "account-a",
            role: "private"
        )
        let sharedA = PersistenceController.historyTokenKey(
            fingerprint: "account-a",
            role: "shared"
        )
        let privateB = PersistenceController.historyTokenKey(
            fingerprint: "account-b",
            role: "private"
        )

        XCTAssertNotEqual(privateA, sharedA)
        XCTAssertNotEqual(privateA, privateB)
        XCTAssertTrue(privateA.contains("account-a.private"))
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
        context.reset()
    }

    private func makeLedger(
        named name: String,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) -> Ledger {
        let ledger = Ledger(context: context)
        context.assign(ledger, to: store)
        ledger.name = name
        ledger.kind = LedgerKind.household.rawValue
        ledger.reportingCurrency = "HKD"
        return ledger
    }

    private func makeCategory(
        named name: String,
        ledger: Ledger,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) -> HowMuch.Category {
        let category = HowMuch.Category(context: context)
        context.assign(category, to: store)
        category.name = name
        category.ledger = ledger
        return category
    }

    private func makeMethod(
        named name: String,
        ledger: Ledger,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) -> PaymentMethod {
        let method = PaymentMethod(context: context)
        context.assign(method, to: store)
        method.name = name
        method.billingCurrency = "HKD"
        method.ledger = ledger
        return method
    }
}
