import CloudKit
import Combine
import CoreData
import Foundation

enum LedgerShareRole: Equatable {
    case owner
    case participant
    case unknown
}

enum LedgerSharePermission: Equatable {
    case readWrite
    case readOnly
    case unknown
}

enum LedgerAccess: Equatable {
    case personalOwner
    case unsharedOwner
    case sharedOwner
    case readWriteParticipant
    case readOnlyParticipant
    case unknown

    var canWrite: Bool {
        switch self {
        case .personalOwner, .unsharedOwner, .sharedOwner, .readWriteParticipant:
            true
        case .readOnlyParticipant, .unknown:
            false
        }
    }

    var canManageSharing: Bool {
        self == .unsharedOwner || self == .sharedOwner
    }

    var canLeaveSharing: Bool {
        self == .readWriteParticipant || self == .readOnlyParticipant
    }

    /// Shared ledgers are never deleted in place: an owner must stop sharing
    /// first, and a participant must leave. That avoids a local delete
    /// synchronizing away everyone else's copy.
    var canDeleteUnsharedLedger: Bool {
        self == .personalOwner || self == .unsharedOwner
    }

    var isShared: Bool {
        switch self {
        case .sharedOwner, .readWriteParticipant, .readOnlyParticipant:
            true
        case .personalOwner, .unsharedOwner, .unknown:
            false
        }
    }

    static let readOnlyExplanation = String(
        localized: "This ledger is read only right now. You can still view Activity and Insights.",
        comment: "Shared ledger read-only explanation"
    )

    static func shared(
        role: LedgerShareRole,
        permission: LedgerSharePermission
    ) -> LedgerAccess {
        switch role {
        case .owner:
            return .sharedOwner
        case .participant:
            switch permission {
            case .readWrite:
                return .readWriteParticipant
            case .readOnly:
                return .readOnlyParticipant
            case .unknown:
                return .unknown
            }
        case .unknown:
            return .unknown
        }
    }
}

enum LedgerAccessError: LocalizedError, Equatable {
    case readOnly
    case accessUnavailable
    case ledgerUnavailable

    var errorDescription: String? {
        switch self {
        case .readOnly:
            LedgerAccess.readOnlyExplanation
        case .accessUnavailable:
            String(
                localized: "This shared ledger's permission could not be verified. Try again after iCloud finishes syncing.",
                comment: "Shared ledger access error"
            )
        case .ledgerUnavailable:
            String(localized: "This ledger is no longer available.", comment: "Ledger access error")
        }
    }
}

extension PersistenceController {
    func access(for ledger: Ledger, forceRefresh: Bool = false) -> LedgerAccess {
        if !forceRefresh,
           let cached = ledgerAccessCache[ledger.objectID],
           Date().timeIntervalSince(cached.resolvedAt) < cacheLifetime(for: cached.value) {
            return cached.value
        }

        let resolved = resolveAccess(for: ledger)
        ledgerAccessCache[ledger.objectID] = CachedLedgerAccess(
            value: resolved,
            resolvedAt: Date()
        )
        return resolved
    }

    func canWrite(_ ledger: Ledger) -> Bool {
        access(for: ledger).canWrite
    }

    func assertWritable(_ ledger: Ledger) throws {
        guard !ledger.isDeleted, ledger.managedObjectContext === viewContext else {
            throw LedgerAccessError.ledgerUnavailable
        }
        // Every shared-ledger mutation must revalidate with CloudKit. Refresh
        // all CloudKit household ledgers because an owner-side share lives in
        // the private store and cannot be identified safely from store alone.
        var forceRefresh = cloudKitEnabled && ledger.isHousehold
        #if DEBUG
        forceRefresh = forceRefresh || ledgerAccessResolverForTesting != nil
        #endif
        switch access(for: ledger, forceRefresh: forceRefresh) {
        case .personalOwner, .unsharedOwner, .sharedOwner, .readWriteParticipant:
            return
        case .readOnlyParticipant:
            throw LedgerAccessError.readOnly
        case .unknown:
            throw LedgerAccessError.accessUnavailable
        }
    }

    func invalidateLedgerAccess(for ledger: Ledger? = nil) {
        if let ledger {
            ledgerAccessCache[ledger.objectID] = nil
        } else {
            ledgerAccessCache.removeAll()
        }
        objectWillChange.send()
    }

    private func resolveAccess(for ledger: Ledger) -> LedgerAccess {
        #if DEBUG
        if let ledgerAccessResolverForTesting {
            return ledgerAccessResolverForTesting(ledger)
        }
        #endif
        guard ledger.managedObjectContext === viewContext,
              let objectStore = ledger.objectID.persistentStore else {
            return .unknown
        }

        let isSharedStore = sharedStore.map { objectStore === $0 } ?? false
        if ledger.isPersonal {
            return isSharedStore ? .unknown : .personalOwner
        }

        guard ledger.isHousehold else { return .unknown }

        if !cloudKitEnabled {
            return isSharedStore ? .unknown : .unsharedOwner
        }

        if ledger.objectID.isTemporaryID {
            return isSharedStore ? .unknown : .unsharedOwner
        }

        guard let persistentCloudKitContainer else {
            return isSharedStore ? .unknown : .unsharedOwner
        }
        do {
            let shares = try persistentCloudKitContainer.fetchShares(matching: [ledger.objectID])
            guard let share = shares[ledger.objectID] else {
                return isSharedStore ? .unknown : .unsharedOwner
            }
            guard let participant = share.currentUserParticipant else {
                return .unknown
            }
            return LedgerAccess.shared(
                role: Self.accessRole(for: participant),
                permission: Self.accessPermission(for: participant)
            )
        } catch {
            return .unknown
        }
    }

    private func cacheLifetime(for access: LedgerAccess) -> TimeInterval {
        switch access {
        case .unknown:
            2
        case .sharedOwner, .readWriteParticipant, .readOnlyParticipant:
            15
        case .personalOwner, .unsharedOwner:
            60
        }
    }

    private static func accessRole(for participant: CKShare.Participant) -> LedgerShareRole {
        switch participant.role {
        case .owner:
            return .owner
        case .privateUser, .administrator:
            return .participant
        case .publicUser, .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static func accessPermission(for participant: CKShare.Participant) -> LedgerSharePermission {
        switch participant.permission {
        case .readWrite:
            return .readWrite
        case .readOnly:
            return .readOnly
        case .none, .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
