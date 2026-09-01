import CoreData
import Foundation

enum LedgerDeletionError: LocalizedError, Equatable {
    case lastPersonalLedger
    case stopSharingFirst
    case leaveSharingFirst
    case accessUnavailable

    var errorDescription: String? {
        switch self {
        case .lastPersonalLedger:
            String(localized: "Keep at least one personal ledger.", comment: "Ledger deletion error")
        case .stopSharingFirst:
            String(localized: "Stop sharing this family ledger first. You can delete the private copy after that.", comment: "Ledger deletion error")
        case .leaveSharingFirst:
            String(localized: "Leave this family ledger from Family Sharing to remove it from this device.", comment: "Ledger deletion error")
        case .accessUnavailable:
            LedgerAccessError.accessUnavailable.errorDescription
        }
    }
}

extension PersistenceController {
    func canDeleteLedger(_ ledger: Ledger) -> Bool {
        do {
            try validateLedgerDeletion(ledger)
            return true
        } catch {
            return false
        }
    }

    func ledgerDeletionBlockReason(_ ledger: Ledger) -> String? {
        do {
            try validateLedgerDeletion(ledger)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Deletes an unshared ledger and its cascaded expenses, categories,
    /// payment methods, and receipts. Shared graphs must be stopped or left
    /// through the existing sharing flow first.
    @discardableResult
    func deleteLedger(_ ledger: Ledger) throws -> UUID? {
        try validateLedgerDeletion(ledger)
        let nextSelectedID = fallbackLedgerID(excluding: ledger.objectID)
        viewContext.delete(ledger)
        do {
            try saveMutationContext()
            return nextSelectedID
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    private func validateLedgerDeletion(_ ledger: Ledger) throws {
        try assertWritable(ledger)
        let access = access(for: ledger)
        switch access {
        case .personalOwner, .unsharedOwner:
            break
        case .sharedOwner:
            throw LedgerDeletionError.stopSharingFirst
        case .readWriteParticipant, .readOnlyParticipant:
            throw LedgerDeletionError.leaveSharingFirst
        case .unknown:
            throw LedgerDeletionError.accessUnavailable
        }
        if ledger.isPersonal, try personalLedgerCount() <= 1 {
            throw LedgerDeletionError.lastPersonalLedger
        }
    }

    private func personalLedgerCount() throws -> Int {
        let request = Ledger.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
        return try viewContext.count(for: request)
    }

    private func fallbackLedgerID(excluding objectID: NSManagedObjectID) -> UUID? {
        let request = Ledger.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ]
        let remaining = (try? viewContext.fetch(request))?.filter {
            $0.objectID != objectID && !$0.isDeleted
        } ?? []
        return (remaining.first(where: \.isPersonal) ?? remaining.first)?.uuid
    }
}
