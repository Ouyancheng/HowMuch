import CoreData
import Foundation

/// Copies a complete ledger graph without retaining any relationship to the
/// source graph. New UUIDs make an owner-retained copy safe even when removing
/// the original CloudKit zone has to be retried.
@MainActor
struct LedgerGraphCopier {
    let context: NSManagedObjectContext

    func copy(
        _ source: Ledger,
        to destinationStore: NSPersistentStore,
        retainedUUID: UUID = UUID()
    ) -> Ledger {
        let destination = Ledger(context: context)
        context.assign(destination, to: destinationStore)
        destination.uuid = retainedUUID
        destination.name = source.name
        destination.kind = source.kind
        destination.reportingCurrency = source.reportingCurrency
        destination.createdAt = source.createdAt
        destination.updatedAt = source.updatedAt

        var copiedCategories: [NSManagedObjectID: Category] = [:]
        for sourceCategory in source.categories ?? [] {
            let category = Category(context: context)
            context.assign(category, to: destinationStore)
            category.uuid = UUID()
            category.name = sourceCategory.name
            category.symbolName = sourceCategory.symbolName
            category.colorHex = sourceCategory.colorHex
            category.sortOrder = sourceCategory.sortOrder
            category.isArchived = sourceCategory.isArchived
            category.createdAt = sourceCategory.createdAt
            copiedCategories[sourceCategory.objectID] = category
        }

        var copiedMethods: [NSManagedObjectID: PaymentMethod] = [:]
        for sourceMethod in source.paymentMethods ?? [] {
            let method = PaymentMethod(context: context)
            context.assign(method, to: destinationStore)
            method.uuid = UUID()
            method.name = sourceMethod.name
            method.billingCurrency = sourceMethod.billingCurrency
            method.kind = sourceMethod.kind
            method.isArchived = sourceMethod.isArchived
            method.createdAt = sourceMethod.createdAt
            copiedMethods[sourceMethod.objectID] = method
        }

        var expensePairs: [(source: Expense, destination: Expense)] = []
        for sourceExpense in source.expenses ?? [] {
            let expense = Expense(context: context)
            context.assign(expense, to: destinationStore)
            expense.uuid = UUID()
            expense.occurredAt = sourceExpense.occurredAt
            expense.merchant = sourceExpense.merchant
            expense.note = sourceExpense.note
            expense.spendAmount = sourceExpense.spendAmount
            expense.spendCurrency = sourceExpense.spendCurrency
            expense.chargedAmount = sourceExpense.chargedAmount
            expense.chargedCurrency = sourceExpense.chargedCurrency
            expense.reportingAmount = sourceExpense.reportingAmount
            expense.reportingCurrency = sourceExpense.reportingCurrency
            expense.createdAt = sourceExpense.createdAt
            expense.updatedAt = sourceExpense.updatedAt
            expense.createdByName = sourceExpense.createdByName
            expense.receiptContentType = sourceExpense.receiptContentType
            expense.receiptData = sourceExpense.receiptData
            expense.receiptFileName = sourceExpense.receiptFileName
            expensePairs.append((sourceExpense, expense))
        }

        // Every destination object has a store before any relationship is set.
        for category in copiedCategories.values {
            category.ledger = destination
        }
        for method in copiedMethods.values {
            method.ledger = destination
        }
        for pair in expensePairs {
            pair.destination.ledger = destination
            if let sourceCategory = pair.source.category {
                pair.destination.category = copiedCategories[sourceCategory.objectID]
            }
            if let sourceMethod = pair.source.paymentMethod {
                pair.destination.paymentMethod = copiedMethods[sourceMethod.objectID]
            }
        }

        return destination
    }
}
