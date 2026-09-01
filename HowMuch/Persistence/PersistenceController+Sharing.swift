import CloudKit
import CoreData
import Foundation
import os.log

private let loggerForSharing = Logger(subsystem: "com.howmuch.app", category: "Sharing")

struct ShareParticipantInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var role: String
    var permission: String
    var isCurrentUser: Bool
}

extension PersistenceController {
    func canShare(_ ledger: Ledger) -> Bool {
        cloudKitEnabled && ledger.isHousehold && !isInSharedStore(ledger)
    }

    func existingShare(for ledger: Ledger) -> CKShare? {
        guard cloudKitEnabled else { return nil }
        do {
            let shares = try container.fetchShares(matching: [ledger.objectID])
            return shares[ledger.objectID]
        } catch {
            loggerForSharing.error("fetchShares failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func participants(for ledger: Ledger) -> [ShareParticipantInfo] {
        guard let share = existingShare(for: ledger) else { return [] }
        return share.participants.map { participant in
            let name = Self.displayName(for: participant)
            let role: String
            switch participant.role {
            case .owner:
                role = String(localized: "Owner", comment: "Share participant role")
            default:
                role = String(localized: "Member", comment: "Share participant role")
            }
            let permission: String
            switch participant.permission {
            case .readWrite:
                permission = String(localized: "Read-Write", comment: "Share permission")
            case .readOnly:
                permission = String(localized: "Read Only", comment: "Share permission")
            default:
                permission = String(localized: "None", comment: "Share permission")
            }
            return ShareParticipantInfo(
                id: participant.userIdentity.userRecordID?.recordName ?? UUID().uuidString,
                name: name,
                role: role,
                permission: permission,
                isCurrentUser: share.currentUserParticipant == participant
            )
        }
    }

    func prepareShare(for ledger: Ledger) async throws -> CKShare {
        guard cloudKitEnabled else {
            throw PersistenceShareError.cloudKitUnavailable
        }
        guard ledger.isHousehold else {
            throw PersistenceShareError.personalLedgerNotShareable
        }
        if let existing = existingShare(for: ledger) {
            return existing
        }
        let (_, share, _) = try await container.share([ledger], to: nil)
        share[CKShare.SystemFieldKey.title] = ledger.wrappedName as CKRecordValue
        share.publicPermission = .none
        try await persist(share, for: ledger)
        return share
    }

    func persist(_ share: CKShare, for ledger: Ledger) async throws {
        guard let store = persistentStore(for: ledger) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.persistUpdatedShare(share, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func acceptShare(metadata: CKShare.Metadata) {
        guard cloudKitEnabled, let sharedStore else { return }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                Task { @MainActor in
                    self.loadError = error.localizedDescription
                }
            }
        }
    }

    func stopSharing(_ ledger: Ledger) async throws {
        guard let share = existingShare(for: ledger) else { return }
        guard let store = persistentStore(for: ledger) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.purgeObjectsAndRecordsInZone(with: share.recordID.zoneID, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cloudKitContainer() -> CKContainer {
        CKContainer(identifier: Self.cloudKitContainerIdentifier)
    }

    private static func displayName(for participant: CKShare.Participant) -> String {
        let components = participant.userIdentity.nameComponents
        let formatter = PersonNameComponentsFormatter()
        let formatted = formatter.string(from: components ?? PersonNameComponents())
        if formatted.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Unknown Participant", comment: "Fallback share participant name")
        }
        return formatted
    }
}

enum PersistenceShareError: LocalizedError {
    case cloudKitUnavailable
    case personalLedgerNotShareable

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            String(localized: "iCloud is not available. Sign in to iCloud to share a family ledger.", comment: "Share error")
        case .personalLedgerNotShareable:
            String(localized: "Personal ledgers stay private. Create a family ledger to share.", comment: "Share error")
        }
    }
}
