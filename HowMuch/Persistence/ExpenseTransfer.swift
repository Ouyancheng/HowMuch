import CloudKit
import CoreData
import Foundation

struct ExpenseEditValues: Codable, Equatable {
    var merchant: String
    var note: String
    var occurredAt: Date
    var spendAmount: Decimal
    var spendCurrency: String
    var chargedAmount: Decimal
    var chargedCurrency: String
    var reportingAmount: Decimal
    var reportingCurrency: String
    var receiptData: Data?
    var receiptFileName: String?
    var receiptContentType: String?
}

enum ExpenseTransferError: LocalizedError {
    case destinationStoreUnavailable
    case invalidDestinationCategory
    case invalidDestinationPaymentMethod
    case crossZoneDestinationRelationship
    case journalPersistenceFailed
    case recoveryStateUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationStoreUnavailable:
            String(localized: "The destination ledger is not available in a persistent store.")
        case .invalidDestinationCategory:
            String(localized: "The selected category does not belong to the destination ledger.")
        case .invalidDestinationPaymentMethod:
            String(localized: "The selected payment method does not belong to the destination ledger.")
        case .crossZoneDestinationRelationship:
            String(localized: "The selected ledger, category, and payment method are not in the same shared data zone.")
        case .journalPersistenceFailed:
            String(localized: "The expense move could not be recorded safely. No data was moved.")
        case .recoveryStateUnavailable:
            String(localized: "A pending expense move could not be verified. Both copies were preserved for recovery.")
        case .saveFailed(let message):
            String(localized: "The expense could not be saved: \(message)")
        }
    }
}

enum ExpenseTransferFailurePoint: Equatable {
    case afterJournal
    case afterDestinationSave
    case afterSourceDelete
}

struct DurableExpenseTransfer: Codable, Equatable {
    let id: UUID
    let accountFingerprint: String
    let sourceObjectURI: String
    let sourceExpenseUUID: UUID
    let destinationLedgerURI: String
    let destinationLedgerUUID: UUID
    let destinationCategoryURI: String
    let destinationCategoryUUID: UUID
    let destinationPaymentMethodURI: String
    let destinationPaymentMethodUUID: UUID
    let createdAt: Date?
    let createdByName: String?
    let values: ExpenseEditValues
}

struct ExpenseTransferJournalStore {
    private static let defaultKey = "expense.transferJournal.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func records(accountFingerprint: String) -> [DurableExpenseTransfer] {
        (decodedRecords() ?? []).filter { $0.accountFingerprint == accountFingerprint }
    }

    @discardableResult
    func save(_ record: DurableExpenseTransfer) -> Bool {
        guard var records = decodedRecords() else { return false }
        records.removeAll { $0.id == record.id }
        records.append(record)
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: key)
        return defaults.synchronize()
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let records = decodedRecords() else { return false }
        let remaining = records.filter { $0.id != id }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: key)
        } else {
            return false
        }
        return defaults.synchronize()
    }

    private func decodedRecords() -> [DurableExpenseTransfer]? {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return try? JSONDecoder().decode([DurableExpenseTransfer].self, from: data)
    }
}

extension PersistenceController {
    /// Saves an expense without ever changing an existing object to point into
    /// another ledger/store/share zone. Cross-store moves use a durable,
    /// idempotent destination-first journal and retain the expense's UUID.
    @discardableResult
    func saveExpense(
        _ source: Expense?,
        to ledger: Ledger,
        category: Category,
        paymentMethod: PaymentMethod,
        values: ExpenseEditValues
    ) throws -> Expense {
        try assertWritable(ledger)
        if let sourceLedger = source?.ledger,
           sourceLedger.objectID != ledger.objectID {
            try assertWritable(sourceLedger)
        }
        guard category.ledger?.objectID == ledger.objectID else {
            throw ExpenseTransferError.invalidDestinationCategory
        }
        guard paymentMethod.ledger?.objectID == ledger.objectID else {
            throw ExpenseTransferError.invalidDestinationPaymentMethod
        }
        guard let destinationStore = ledger.objectID.persistentStore else {
            throw ExpenseTransferError.destinationStoreUnavailable
        }
        guard destinationObjectsCanRelate(
            ledger: ledger,
            category: category,
            paymentMethod: paymentMethod,
            store: destinationStore
        ) else {
            throw ExpenseTransferError.crossZoneDestinationRelationship
        }

        let canEditInPlace = source?.ledger?.objectID == ledger.objectID
            && source.map { objectsShareStoreAndZone([$0, ledger]) } == true
        if let source, canEditInPlace {
            apply(values, to: source, ledger: ledger, category: category, paymentMethod: paymentMethod)
            return try saveExpenseMutation(source)
        }

        if let source {
            return try transferExpense(
                source,
                to: ledger,
                category: category,
                paymentMethod: paymentMethod,
                destinationStore: destinationStore,
                values: values
            )
        }

        let destination = Expense(context: viewContext)
        viewContext.assign(destination, to: destinationStore)
        destination.createdByName = currentParticipantDisplayName(for: ledger)
            ?? String(localized: "Me", comment: "Local expense creator fallback")
        apply(values, to: destination, ledger: ledger, category: category, paymentMethod: paymentMethod)
        return try saveExpenseMutation(destination)
    }

    func recoverPendingExpenseTransfers() {
        let accountFingerprint = expenseTransferAccountFingerprint
        for record in expenseTransferJournalStore.records(accountFingerprint: accountFingerprint) {
            do {
                _ = try continueExpenseTransfer(record)
            } catch {
                let message = String(
                    localized: "A pending expense move is waiting for safe recovery: \(error.localizedDescription)",
                    comment: "Expense transfer recovery diagnostic"
                )
                diagnostic = PersistenceDiagnostic(kind: .save, message: message)
            }
        }
    }

    private func transferExpense(
        _ source: Expense,
        to ledger: Ledger,
        category: Category,
        paymentMethod: PaymentMethod,
        destinationStore: NSPersistentStore,
        values: ExpenseEditValues
    ) throws -> Expense {
        let requiredObjects: [NSManagedObject] = [source, ledger, category, paymentMethod]
        if requiredObjects.contains(where: \.objectID.isTemporaryID) {
            try viewContext.obtainPermanentIDs(for: requiredObjects.filter(\.objectID.isTemporaryID))
        }
        guard let sourceUUID = source.uuid,
              let ledgerUUID = ledger.uuid,
              let categoryUUID = category.uuid,
              let paymentMethodUUID = paymentMethod.uuid else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        let sourceURI = source.objectID.uriRepresentation().absoluteString
        let pending = expenseTransferJournalStore
            .records(accountFingerprint: expenseTransferAccountFingerprint)
            .filter {
                $0.sourceExpenseUUID == sourceUUID
                    && $0.sourceObjectURI == sourceURI
            }
        guard pending.count <= 1 else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        if let existing = pending.first {
            return try continueExpenseTransfer(existing, source: source)
        }

        let record = DurableExpenseTransfer(
            id: UUID(),
            accountFingerprint: expenseTransferAccountFingerprint,
            sourceObjectURI: sourceURI,
            sourceExpenseUUID: sourceUUID,
            destinationLedgerURI: ledger.objectID.uriRepresentation().absoluteString,
            destinationLedgerUUID: ledgerUUID,
            destinationCategoryURI: category.objectID.uriRepresentation().absoluteString,
            destinationCategoryUUID: categoryUUID,
            destinationPaymentMethodURI: paymentMethod.objectID.uriRepresentation().absoluteString,
            destinationPaymentMethodUUID: paymentMethodUUID,
            createdAt: source.createdAt,
            createdByName: source.createdByName,
            values: values
        )
        guard expenseTransferJournalStore.save(record) else {
            throw ExpenseTransferError.journalPersistenceFailed
        }
        try injectExpenseTransferFailure(at: .afterJournal)
        return try continueExpenseTransfer(
            record,
            source: source,
            ledger: ledger,
            category: category,
            paymentMethod: paymentMethod
        )
    }

    @discardableResult
    private func continueExpenseTransfer(
        _ record: DurableExpenseTransfer,
        source suppliedSource: Expense? = nil,
        ledger suppliedLedger: Ledger? = nil,
        category suppliedCategory: Category? = nil,
        paymentMethod suppliedPaymentMethod: PaymentMethod? = nil
    ) throws -> Expense {
        guard record.accountFingerprint == expenseTransferAccountFingerprint else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        let ledger = try suppliedLedger ?? existingObject(
            uri: record.destinationLedgerURI,
            uuid: record.destinationLedgerUUID,
            as: Ledger.self
        )
        let category = try suppliedCategory ?? existingObject(
            uri: record.destinationCategoryURI,
            uuid: record.destinationCategoryUUID,
            as: Category.self
        )
        let paymentMethod = try suppliedPaymentMethod ?? existingObject(
            uri: record.destinationPaymentMethodURI,
            uuid: record.destinationPaymentMethodUUID,
            as: PaymentMethod.self
        )
        guard category.ledger?.objectID == ledger.objectID,
              paymentMethod.ledger?.objectID == ledger.objectID,
              let destinationStore = ledger.objectID.persistentStore,
              destinationObjectsCanRelate(
                ledger: ledger,
                category: category,
                paymentMethod: paymentMethod,
                store: destinationStore
              ) else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        try assertWritable(ledger)

        let source = suppliedSource ?? existingExpense(uri: record.sourceObjectURI)
        let destination = try destinationExpense(
            uuid: record.sourceExpenseUUID,
            ledger: ledger,
            store: destinationStore
        ) ?? {
            let expense = Expense(context: viewContext)
            viewContext.assign(expense, to: destinationStore)
            expense.uuid = record.sourceExpenseUUID
            expense.createdAt = record.createdAt
            expense.createdByName = record.createdByName
            apply(
                record.values,
                to: expense,
                ledger: ledger,
                category: category,
                paymentMethod: paymentMethod
            )
            return expense
        }()

        if destination.isInserted || destination.hasChanges {
            _ = try saveExpenseMutation(destination)
        }
        try injectExpenseTransferFailure(at: .afterDestinationSave)

        if let source, !source.isDeleted {
            guard source.uuid == record.sourceExpenseUUID,
                  source.objectID != destination.objectID,
                  let sourceLedger = source.ledger else {
                throw ExpenseTransferError.recoveryStateUnavailable
            }
            try assertWritable(sourceLedger)
            viewContext.delete(source)
            do {
                try saveMutationContext()
            } catch {
                viewContext.rollback()
                throw error
            }
        }
        try injectExpenseTransferFailure(at: .afterSourceDelete)
        guard expenseTransferJournalStore.remove(id: record.id) else {
            // Source deletion is already durable. Keep the idempotent journal;
            // launch recovery will observe the missing source and clear it.
            throw ExpenseTransferError.journalPersistenceFailed
        }
        return destination
    }

    private func apply(
        _ values: ExpenseEditValues,
        to destination: Expense,
        ledger: Ledger,
        category: Category,
        paymentMethod: PaymentMethod
    ) {
        destination.merchant = values.merchant
        destination.note = values.note
        destination.occurredAt = values.occurredAt
        destination.updatedAt = Date()
        destination.spendAmount = values.spendAmount as NSDecimalNumber
        destination.spendCurrency = values.spendCurrency
        destination.chargedAmount = values.chargedAmount as NSDecimalNumber
        destination.chargedCurrency = values.chargedCurrency
        destination.reportingAmount = values.reportingAmount as NSDecimalNumber
        destination.reportingCurrency = values.reportingCurrency
        destination.receiptData = values.receiptData
        destination.receiptFileName = values.receiptFileName
        destination.receiptContentType = values.receiptContentType
        destination.ledger = ledger
        destination.category = category
        destination.paymentMethod = paymentMethod
    }

    private func saveExpenseMutation(_ expense: Expense) throws -> Expense {
        do {
            try saveMutationContext()
            return expense
        } catch {
            viewContext.rollback()
            if error is LedgerAccessError || error is PersistenceMutationError {
                throw error
            }
            throw ExpenseTransferError.saveFailed(error.localizedDescription)
        }
    }

    private func existingExpense(uri: String) -> Expense? {
        guard let url = URL(string: uri),
              let objectID = container.persistentStoreCoordinator.managedObjectID(
                forURIRepresentation: url
              ),
              let object = try? viewContext.existingObject(with: objectID) as? Expense,
              !object.isDeleted else {
            return nil
        }
        return object
    }

    private func existingObject<T: NSManagedObject>(
        uri: String,
        uuid: UUID,
        as type: T.Type
    ) throws -> T {
        guard let url = URL(string: uri),
              let objectID = container.persistentStoreCoordinator.managedObjectID(
                forURIRepresentation: url
              ),
              let object = try? viewContext.existingObject(with: objectID) as? T,
              !object.isDeleted,
              object.value(forKey: "uuid") as? UUID == uuid else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        return object
    }

    private func destinationExpense(
        uuid: UUID,
        ledger: Ledger,
        store: NSPersistentStore
    ) throws -> Expense? {
        let request = Expense.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        let matches = try viewContext.fetch(request).filter {
            !$0.isDeleted
                && $0.ledger?.objectID == ledger.objectID
                && $0.objectID.persistentStore === store
        }
        guard matches.count <= 1 else {
            throw ExpenseTransferError.recoveryStateUnavailable
        }
        return matches.first
    }

    private var expenseTransferAccountFingerprint: String {
        currentAccountFingerprint ?? (isLocalOnly ? "local" : "test")
    }

    private func injectExpenseTransferFailure(at point: ExpenseTransferFailurePoint) throws {
        #if DEBUG
        try expenseTransferFailureInjector?(point)
        #endif
    }

    private func destinationObjectsCanRelate(
        ledger: Ledger,
        category: Category,
        paymentMethod: PaymentMethod,
        store: NSPersistentStore
    ) -> Bool {
        let objects: [NSManagedObject] = [ledger, category, paymentMethod]
        guard objects.allSatisfy({ $0.objectID.persistentStore === store }) else {
            return false
        }
        return objectsShareStoreAndZone(objects)
    }

    private func objectsShareStoreAndZone(_ objects: [NSManagedObject]) -> Bool {
        guard let firstStore = objects.first?.objectID.persistentStore,
              objects.allSatisfy({ $0.objectID.persistentStore === firstStore }) else {
            return false
        }
        // CloudKit record zones distinguish separate shares that live in the
        // same persistent store. Unsynced/new records fall back to the strict
        // ledger ownership and store checks performed by the caller.
        let zones = objects.compactMap { object -> CKRecordZone.ID? in
            guard !object.objectID.isTemporaryID else { return nil }
            return persistentCloudKitContainer?.recordID(for: object.objectID)?.zoneID
        }
        return zones.isEmpty || zones.allSatisfy { $0 == zones[0] }
    }
}
