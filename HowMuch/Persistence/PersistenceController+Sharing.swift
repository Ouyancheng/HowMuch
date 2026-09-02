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

enum SharingMembershipRole: String, Codable {
    case owner
    case participant
}

struct StopSharingRetry {
    fileprivate let originalLedgerID: NSManagedObjectID
    fileprivate let originalLedgerUUID: UUID
    fileprivate let zoneID: CKRecordZone.ID
    fileprivate let retainedLedgerID: NSManagedObjectID?
    fileprivate let retainedLedgerUUID: UUID?
    fileprivate let role: SharingMembershipRole
    fileprivate let accountRecordName: String
    fileprivate let accountFingerprint: String

    @MainActor
    fileprivate var durableRecord: DurableStopSharingRetry {
        DurableStopSharingRetry(
            containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
            accountRecordName: accountRecordName,
            originalLedgerUUID: originalLedgerUUID,
            originalObjectURI: originalLedgerID.uriRepresentation().absoluteString,
            retainedLedgerUUID: retainedLedgerUUID,
            retainedObjectURI: retainedLedgerID?.uriRepresentation().absoluteString,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            role: role,
            accountFingerprint: accountFingerprint
        )
    }
}

struct StopSharingResult {
    let selectedLedgerID: UUID?
    let retainedLedgerID: NSManagedObjectID?
    let role: SharingMembershipRole
}

extension PersistenceController {
    var canSafelyStopSharing: Bool {
        loadState == .loaded
            && destructiveSharingReady
            && syncActivity != .settingUp
            && syncActivity != .importing
            && syncActivity != .failed
    }

    func canShare(_ ledger: Ledger) -> Bool {
        cloudKitEnabled && ledger.isHousehold && access(for: ledger) == .unsharedOwner
    }

    func sharingRole(for ledger: Ledger) -> SharingMembershipRole {
        access(for: ledger).canLeaveSharing ? .participant : .owner
    }

    func existingShare(for ledger: Ledger) -> CKShare? {
        guard cloudKitEnabled else { return nil }
        do {
            let shares = try persistentCloudKitContainer?.fetchShares(matching: [ledger.objectID])
            return shares?[ledger.objectID]
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

    func currentParticipantDisplayName(for ledger: Ledger) -> String? {
        guard let participant = existingShare(for: ledger)?.currentUserParticipant else {
            return nil
        }
        return Self.displayName(for: participant)
    }

    func prepareShare(for ledger: Ledger) async throws -> CKShare {
        guard cloudKitEnabled else {
            throw PersistenceShareError.cloudKitUnavailable
        }
        guard ledger.isHousehold else {
            throw PersistenceShareError.personalLedgerNotShareable
        }
        guard access(for: ledger).canManageSharing else {
            throw PersistenceShareError.ownerPermissionRequired
        }
        if let existing = existingShare(for: ledger) {
            return existing
        }
        guard let persistentCloudKitContainer else {
            throw PersistenceShareError.cloudKitUnavailable
        }
        let (_, share, _) = try await persistentCloudKitContainer.share([ledger], to: nil)
        share[CKShare.SystemFieldKey.title] = ledger.wrappedName as CKRecordValue
        share.publicPermission = .none
        try await persist(share, for: ledger)
        return share
    }

    func persist(_ share: CKShare, for ledger: Ledger) async throws {
        guard let store = ledger.objectID.persistentStore else {
            throw PersistenceShareError.persistentStoreUnavailable
        }
        defer { invalidateLedgerAccess(for: ledger) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let persistentCloudKitContainer else {
                continuation.resume(throwing: PersistenceShareError.cloudKitUnavailable)
                return
            }
            persistentCloudKitContainer.persistUpdatedShare(share, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func acceptShare(metadata: CKShare.Metadata) {
        pendingShareMetadata = metadata
        hasPendingShareInvitation = true
        retryPendingShareInvitation()
    }

    func retryPendingShareInvitation() {
        guard let metadata = pendingShareMetadata else { return }
        guard cloudKitEnabled else {
            shareError = String(
                localized: "This invitation is waiting for iCloud sharing to become available.",
                comment: "Share acceptance error"
            )
            return
        }
        guard loadState == .loaded, let sharedStore else {
            shareError = String(
                localized: "This invitation is waiting for your iCloud data stores to finish loading. Retry when iCloud is available.",
                comment: "Share acceptance error"
            )
            return
        }

        shareError = nil
        guard let persistentCloudKitContainer else {
            shareError = String(
                localized: "This invitation is waiting for iCloud sharing to become available.",
                comment: "Share acceptance error"
            )
            return
        }
        persistentCloudKitContainer.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    self.shareError = String(
                        localized: "The invitation could not be accepted: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))",
                        comment: "Share acceptance error"
                    )
                } else {
                    self.pendingShareMetadata = nil
                    self.hasPendingShareInvitation = false
                    self.shareError = nil
                }
                self.invalidateLedgerAccess()
            }
        }
    }

    /// Completes a stop initiated inside UICloudSharingController. The share
    /// passed by the sheet is authoritative because CloudKit may already have
    /// removed it by the time this callback runs.
    func completeSystemStopSharing(
        _ ledger: Ledger,
        knownShare share: CKShare
    ) async throws -> StopSharingResult {
        guard cloudKitEnabled else {
            throw PersistenceShareError.cloudKitUnavailable
        }
        guard canSafelyStopSharing else {
            throw PersistenceShareError.cloudKitWorkInProgress
        }
        guard ledger.isHousehold,
              ledger.managedObjectContext === viewContext,
              ledger.uuid != nil,
              ledger.objectID.persistentStore != nil else {
            throw PersistenceShareError.systemStopSourceUnavailable
        }
        guard let role = Self.membershipRole(in: share) else {
            throw PersistenceShareError.sharingMembershipUnavailable
        }

        let ledgerID = ledger.objectID
        guard systemStopSharingInProgress.insert(ledgerID).inserted else {
            throw PersistenceShareError.stopAlreadyInProgress
        }
        defer { systemStopSharingInProgress.remove(ledgerID) }

        guard let accountFingerprint = currentAccountFingerprint else {
            throw PersistenceShareError.accountIdentityUnavailable(
                String(localized: "The scoped iCloud account is not loaded.")
            )
        }
        let accountRecordName: String
        if let knownRecordName = share.currentUserParticipant?
            .userIdentity.userRecordID?.recordName {
            accountRecordName = knownRecordName
        } else {
            do {
                accountRecordName = try await cloudKitContainer().userRecordID().recordName
            } catch {
                throw PersistenceShareError.accountIdentityUnavailable(error.localizedDescription)
            }
        }
        guard CloudIdentityFingerprint.make(
            containerIdentifier: Self.cloudKitContainerIdentifier,
            accountRecordName: accountRecordName
        ) == accountFingerprint else {
            throw PersistenceShareError.accountIdentityUnavailable(
                String(localized: "The system share belongs to a different iCloud account.")
            )
        }
        guard canSafelyStopSharing else {
            throw PersistenceShareError.cloudKitWorkInProgress
        }

        let retry = try prepareSystemStopRetry(
            for: ledger,
            role: role,
            zoneID: share.recordID.zoneID,
            accountRecordName: accountRecordName,
            accountFingerprint: accountFingerprint
        )
        return try await retryStopSharing(retry)
    }

    /// Builds or restores the durable copy intent used by the system-sheet
    /// callback. Kept separate from CloudKit calls so idempotence is testable.
    func prepareSystemStopRetry(
        for ledger: Ledger,
        role: SharingMembershipRole,
        zoneID: CKRecordZone.ID,
        accountRecordName: String,
        accountFingerprint: String,
        retryStore: StopSharingRetryStore = StopSharingRetryStore()
    ) throws -> StopSharingRetry {
        guard ledger.managedObjectContext === viewContext,
              let originalUUID = ledger.uuid,
              ledger.objectID.persistentStore != nil else {
            throw PersistenceShareError.systemStopSourceUnavailable
        }

        let originalURI = ledger.objectID.uriRepresentation().absoluteString
        let durable: DurableStopSharingRetry
        switch retryStore.lookup(
            originalLedgerUUID: originalUUID,
            originalObjectURI: originalURI
        ) {
        case .missing:
            let intent = StopSharingRetry(
                originalLedgerID: ledger.objectID,
                originalLedgerUUID: originalUUID,
                zoneID: zoneID,
                retainedLedgerID: nil,
                retainedLedgerUUID: role == .owner ? UUID() : nil,
                role: role,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint
            )
            guard retryStore.save(intent.durableRecord) else {
                throw PersistenceShareError.retryStatePersistenceFailed(retry: intent)
            }
            durable = intent.durableRecord
        case .unsafe:
            throw PersistenceShareError.unsafeRetryState
        case .found(let record):
            durable = record
        }

        guard durable.matches(
            containerIdentifier: Self.cloudKitContainerIdentifier,
            accountRecordName: accountRecordName,
            accountFingerprint: accountFingerprint,
            originalLedgerUUID: originalUUID,
            originalObjectURI: originalURI,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            role: role
        ) else {
            throw PersistenceShareError.unsafeRetryState
        }

        if role == .participant {
            guard durable.retainedLedgerUUID == nil,
                  durable.retainedObjectURI == nil else {
                throw PersistenceShareError.unsafeRetryState
            }
            let retry = StopSharingRetry(
                originalLedgerID: ledger.objectID,
                originalLedgerUUID: originalUUID,
                zoneID: zoneID,
                retainedLedgerID: nil,
                retainedLedgerUUID: nil,
                role: role,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint
            )
            pendingStopSharingRetries[ledger.objectID] = retry
            return retry
        }

        guard let retainedUUID = durable.retainedLedgerUUID else {
            throw PersistenceShareError.unsafeRetryState
        }
        if let retained = try retainedLedger(with: retainedUUID) {
            if let expectedURI = durable.retainedObjectURI,
               retained.objectID.uriRepresentation().absoluteString != expectedURI {
                throw PersistenceShareError.unsafeRetryState
            }
            let retry = StopSharingRetry(
                originalLedgerID: ledger.objectID,
                originalLedgerUUID: originalUUID,
                zoneID: zoneID,
                retainedLedgerID: retained.objectID,
                retainedLedgerUUID: retainedUUID,
                role: role,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint
            )
            guard retryStore.save(retry.durableRecord) else {
                pendingStopSharingRetries[ledger.objectID] = retry
                throw PersistenceShareError.retryStatePersistenceFailed(retry: retry)
            }
            pendingStopSharingRetries[ledger.objectID] = retry
            return retry
        }

        // A completed record whose retained object disappeared must never
        // trigger another copy. Only an explicit pre-copy intent may do so.
        guard durable.retainedObjectURI == nil else {
            throw PersistenceShareError.retainedCopyUnavailable
        }
        try validateSourceGraphForRetention(ledger)
        guard let privateStore else {
            throw PersistenceShareError.privateStoreUnavailable
        }

        let retained = LedgerGraphCopier(context: viewContext).copy(
            ledger,
            to: privateStore,
            retainedUUID: retainedUUID
        )
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
            throw PersistenceShareError.privateCopyFailed(error.localizedDescription)
        }

        let retry = StopSharingRetry(
            originalLedgerID: ledger.objectID,
            originalLedgerUUID: originalUUID,
            zoneID: zoneID,
            retainedLedgerID: retained.objectID,
            retainedLedgerUUID: retainedUUID,
            role: role,
            accountRecordName: accountRecordName,
            accountFingerprint: accountFingerprint
        )
        pendingStopSharingRetries[ledger.objectID] = retry
        guard retryStore.save(retry.durableRecord) else {
            throw PersistenceShareError.retryStatePersistenceFailed(retry: retry)
        }
        return retry
    }

    private func retainedLedger(with uuid: UUID) throws -> Ledger? {
        let request = Ledger.fetchRequest()
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        let matches = try viewContext.fetch(request).filter {
            !$0.isDeleted
                && $0.objectID.persistentStore === privateStore
                && !isInSharedStore($0)
        }
        guard matches.count <= 1 else {
            throw PersistenceShareError.unsafeRetryState
        }
        return matches.first
    }

    private func validateSourceGraphForRetention(_ ledger: Ledger) throws {
        guard !ledger.isDeleted,
              let existing = try? viewContext.existingObject(with: ledger.objectID),
              existing === ledger,
              !(ledger.categories?.isEmpty ?? true),
              !(ledger.paymentMethods?.isEmpty ?? true) else {
            throw PersistenceShareError.systemStopSourceUnavailable
        }
    }

    private static func membershipRole(in share: CKShare) -> SharingMembershipRole? {
        guard let participant = share.currentUserParticipant else { return nil }
        switch participant.role {
        case .owner:
            return .owner
        case .privateUser, .administrator:
            return .participant
        case .publicUser, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Owners first retain a complete private graph and then purge the shared
    /// zone. Participants only purge the graph imported into the shared store.
    func stopSharing(
        _ ledger: Ledger,
        retry suppliedRetry: StopSharingRetry? = nil
    ) async throws -> StopSharingResult {
        guard cloudKitEnabled else {
            throw PersistenceShareError.cloudKitUnavailable
        }
        guard canSafelyStopSharing else {
            throw PersistenceShareError.cloudKitWorkInProgress
        }
        guard ledger.isHousehold else {
            throw PersistenceShareError.personalLedgerNotShareable
        }
        guard !ledger.isDeleted, ledger.managedObjectContext === viewContext else {
            throw PersistenceShareError.invalidLedger
        }
        let ledgerAccess = access(for: ledger, forceRefresh: true)
        guard ledgerAccess.canManageSharing || ledgerAccess.canLeaveSharing else {
            throw PersistenceShareError.sharingMembershipUnavailable
        }
        guard ledger.uuid != nil else {
            throw PersistenceShareError.invalidLedger
        }

        let accountRecordName: String
        do {
            accountRecordName = try await cloudKitContainer().userRecordID().recordName
        } catch {
            throw PersistenceShareError.accountIdentityUnavailable(error.localizedDescription)
        }
        guard let accountFingerprint = currentAccountFingerprint else {
            throw PersistenceShareError.accountIdentityUnavailable(
                String(localized: "The scoped iCloud account is not loaded.")
            )
        }
        let role: SharingMembershipRole = ledgerAccess.canLeaveSharing ? .participant : .owner
        guard canSafelyStopSharing else {
            throw PersistenceShareError.cloudKitWorkInProgress
        }

        if let retry = suppliedRetry ?? pendingStopSharingRetries[ledger.objectID] {
            try validateRetry(
                retry,
                for: ledger,
                role: role,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint
            )
            return try await retryStopSharing(retry)
        }

        switch try restoredRetry(
            for: ledger,
            role: role,
            accountRecordName: accountRecordName,
            accountFingerprint: accountFingerprint
        ) {
        case .some(let retry):
            pendingStopSharingRetries[ledger.objectID] = retry
            return try await retryStopSharing(retry)
        case .none:
            break
        }

        let share: CKShare
        do {
            guard let persistentCloudKitContainer else {
                throw PersistenceShareError.cloudKitUnavailable
            }
            let shares = try persistentCloudKitContainer.fetchShares(matching: [ledger.objectID])
            guard let fetchedShare = shares[ledger.objectID] else {
                throw PersistenceShareError.shareNotFound
            }
            share = fetchedShare
        } catch let error as PersistenceShareError {
            throw error
        } catch {
            throw PersistenceShareError.shareLookupFailed(error.localizedDescription)
        }

        let retry = try prepareSystemStopRetry(
            for: ledger,
            role: role,
            zoneID: share.recordID.zoneID,
            accountRecordName: accountRecordName,
            accountFingerprint: accountFingerprint
        )
        return try await retryStopSharing(retry)
    }

    private func restoredRetry(
        for ledger: Ledger,
        role: SharingMembershipRole,
        accountRecordName: String,
        accountFingerprint: String
    ) throws -> StopSharingRetry? {
        guard let ledgerUUID = ledger.uuid else {
            throw PersistenceShareError.invalidLedger
        }
        let objectURI = ledger.objectID.uriRepresentation().absoluteString
        switch StopSharingRetryStore().lookup(
            originalLedgerUUID: ledgerUUID,
            originalObjectURI: objectURI
        ) {
        case .missing:
            return nil
        case .unsafe:
            throw PersistenceShareError.unsafeRetryState
        case .found(let record):
            guard let currentZoneID = currentZoneID(for: ledger) else {
                throw PersistenceShareError.retryIdentityUnavailable
            }
            guard record.matches(
                containerIdentifier: Self.cloudKitContainerIdentifier,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint,
                originalLedgerUUID: ledgerUUID,
                originalObjectURI: objectURI,
                zoneName: currentZoneID.zoneName,
                zoneOwnerName: currentZoneID.ownerName,
                role: role
            ) else {
                throw PersistenceShareError.unsafeRetryState
            }

            let retainedLedgerID = try restoredRetainedLedgerID(from: record, role: role)
            guard retainedLedgerID != ledger.objectID else {
                throw PersistenceShareError.unsafeRetryState
            }
            return StopSharingRetry(
                originalLedgerID: ledger.objectID,
                originalLedgerUUID: ledgerUUID,
                zoneID: currentZoneID,
                retainedLedgerID: retainedLedgerID,
                retainedLedgerUUID: record.retainedLedgerUUID,
                role: role,
                accountRecordName: accountRecordName,
                accountFingerprint: accountFingerprint
            )
        }
    }

    private func validateRetry(
        _ retry: StopSharingRetry,
        for ledger: Ledger,
        role: SharingMembershipRole,
        accountRecordName: String,
        accountFingerprint: String
    ) throws {
        guard retry.originalLedgerID == ledger.objectID,
              retry.originalLedgerUUID == ledger.uuid,
              retry.role == role,
              retry.accountRecordName == accountRecordName,
              retry.accountFingerprint == accountFingerprint else {
            throw PersistenceShareError.invalidRetry
        }
        guard let currentZoneID = currentZoneID(for: ledger) else {
            throw PersistenceShareError.retryIdentityUnavailable
        }
        guard currentZoneID == retry.zoneID else {
            throw PersistenceShareError.unsafeRetryState
        }
        let retainedLedgerID = try validatedRetainedLedgerID(
            retry.retainedLedgerID,
            uuid: retry.retainedLedgerUUID,
            role: role
        )
        guard retainedLedgerID != ledger.objectID else {
            throw PersistenceShareError.unsafeRetryState
        }
    }

    private func currentZoneID(for ledger: Ledger) -> CKRecordZone.ID? {
        if let recordID = persistentCloudKitContainer?.recordID(for: ledger.objectID) {
            return recordID.zoneID
        }
        return try? persistentCloudKitContainer?.fetchShares(matching: [ledger.objectID])[ledger.objectID]?.recordID.zoneID
    }

    private func restoredRetainedLedgerID(
        from record: DurableStopSharingRetry,
        role: SharingMembershipRole
    ) throws -> NSManagedObjectID? {
        if role == .participant {
            guard record.retainedLedgerUUID == nil, record.retainedObjectURI == nil else {
                throw PersistenceShareError.unsafeRetryState
            }
            return nil
        }
        guard let uuid = record.retainedLedgerUUID,
              let rawURI = record.retainedObjectURI,
              let uri = URL(string: rawURI),
              let objectID = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri) else {
            throw PersistenceShareError.retainedCopyUnavailable
        }
        return try validatedRetainedLedgerID(objectID, uuid: uuid, role: role)
    }

    private func validatedRetainedLedgerID(
        _ objectID: NSManagedObjectID?,
        uuid: UUID?,
        role: SharingMembershipRole
    ) throws -> NSManagedObjectID? {
        if role == .participant {
            guard objectID == nil, uuid == nil else {
                throw PersistenceShareError.unsafeRetryState
            }
            return nil
        }
        guard let objectID,
              let uuid,
              let existing = try? viewContext.existingObject(with: objectID),
              let retained = existing as? Ledger,
              !retained.isDeleted,
              retained.uuid == uuid,
              retained.objectID.persistentStore === privateStore,
              !isInSharedStore(retained) else {
            throw PersistenceShareError.retainedCopyUnavailable
        }
        return retained.objectID
    }

    private func retryStopSharing(
        _ retry: StopSharingRetry,
        store suppliedStore: NSPersistentStore? = nil
    ) async throws -> StopSharingResult {
        guard canSafelyStopSharing else {
            throw PersistenceShareError.cloudKitWorkInProgress
        }
        guard let store = suppliedStore ?? retry.originalLedgerID.persistentStore else {
            throw PersistenceShareError.persistentStoreUnavailable
        }
        guard StopSharingRetryStore().save(retry.durableRecord) else {
            throw PersistenceShareError.retryStatePersistenceFailed(retry: retry)
        }
        do {
            try await purge(zoneID: retry.zoneID, from: store)
            pendingStopSharingRetries[retry.originalLedgerID] = nil
            if !StopSharingRetryStore().remove(
                originalLedgerUUID: retry.originalLedgerUUID,
                originalObjectURI: retry.originalLedgerID.uriRepresentation().absoluteString
            ) {
                loggerForSharing.error("Unable to clear durable stop-sharing retry state")
            }
            invalidateLedgerAccess()
            return stopSharingResult(for: retry)
        } catch {
            pendingStopSharingRetries[retry.originalLedgerID] = retry
            throw PersistenceShareError.purgeFailed(
                message: error.localizedDescription,
                retry: retry
            )
        }
    }

    private func purge(zoneID: CKRecordZone.ID, from store: NSPersistentStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let persistentCloudKitContainer else {
                continuation.resume(throwing: PersistenceShareError.cloudKitUnavailable)
                return
            }
            persistentCloudKitContainer.purgeObjectsAndRecordsInZone(with: zoneID, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopSharingResult(for retry: StopSharingRetry) -> StopSharingResult {
        if retry.role == .owner {
            return StopSharingResult(
                selectedLedgerID: retry.retainedLedgerUUID,
                retainedLedgerID: retry.retainedLedgerID,
                role: retry.role
            )
        }

        let request = Ledger.fetchRequest()
        let available = (try? viewContext.fetch(request))?.filter {
            $0.objectID != retry.originalLedgerID
        } ?? []
        let privateLedgers = available.filter { !isInSharedStore($0) }
        let fallback = privateLedgers.first(where: \.isPersonal)
            ?? privateLedgers.first
            ?? available.first
        return StopSharingResult(
            selectedLedgerID: fallback?.uuid,
            retainedLedgerID: nil,
            role: retry.role
        )
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
    case cloudKitWorkInProgress
    case accountIdentityUnavailable(String)
    case personalLedgerNotShareable
    case ownerPermissionRequired
    case sharingMembershipUnavailable
    case stopAlreadyInProgress
    case systemStopSourceUnavailable
    case invalidLedger
    case invalidRetry
    case retryIdentityUnavailable
    case unsafeRetryState
    case retainedCopyUnavailable
    case retryStatePersistenceFailed(retry: StopSharingRetry)
    case shareNotFound
    case shareLookupFailed(String)
    case persistentStoreUnavailable
    case privateStoreUnavailable
    case privateCopyFailed(String)
    case purgeFailed(message: String, retry: StopSharingRetry)

    var retry: StopSharingRetry? {
        switch self {
        case .purgeFailed(_, let retry), .retryStatePersistenceFailed(let retry):
            return retry
        default:
            return nil
        }
    }

    var retainedLedgerID: UUID? {
        retry?.retainedLedgerUUID
    }

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            String(localized: "iCloud is not available. Sign in to iCloud to share a family ledger.", comment: "Share error")
        case .cloudKitWorkInProgress:
            String(localized: "Wait for iCloud setup or import to finish before stopping or leaving this share. No data was copied or removed.", comment: "Share error")
        case .accountIdentityUnavailable(let message):
            String(localized: "Your iCloud account could not be verified. Sharing was not changed: \(message)", comment: "Share error")
        case .personalLedgerNotShareable:
            String(localized: "Personal ledgers stay private. Create a family ledger to share.", comment: "Share error")
        case .ownerPermissionRequired:
            String(localized: "Only the owner can share or manage this family ledger.", comment: "Share error")
        case .sharingMembershipUnavailable:
            String(localized: "Your sharing membership could not be verified. Wait for iCloud to finish syncing, then try again.", comment: "Share error")
        case .stopAlreadyInProgress:
            String(localized: "A stop-sharing operation is already in progress.", comment: "Share error")
        case .systemStopSourceUnavailable:
            String(localized: "Sharing stopped in iCloud, but the complete source ledger is no longer available to retain safely. No empty private copy was created. Keep this screen open and retry after iCloud finishes syncing.", comment: "Share error")
        case .invalidLedger:
            String(localized: "This ledger is no longer available.", comment: "Share error")
        case .invalidRetry:
            String(localized: "This stop-sharing retry no longer matches the ledger.", comment: "Share error")
        case .retryIdentityUnavailable:
            String(localized: "The shared iCloud zone could not be verified. The retained copy was not duplicated and sharing was not changed.", comment: "Share error")
        case .unsafeRetryState:
            String(localized: "Saved stop-sharing state does not match the current iCloud account, ledger, or shared zone. No copy was created and no shared data was removed.", comment: "Share error")
        case .retainedCopyUnavailable:
            String(localized: "The previously retained private copy could not be verified. No additional copy was created and no shared data was removed.", comment: "Share error")
        case .retryStatePersistenceFailed(let retry):
            if retry.retainedLedgerID != nil {
                String(localized: "Your private copy was saved, but safe retry information could not be stored. Retry before stopping sharing.", comment: "Share error")
            } else {
                String(localized: "Safe retry information could not be stored, so the shared data was not removed.", comment: "Share error")
            }
        case .shareNotFound:
            String(localized: "The iCloud share could not be found.", comment: "Share error")
        case .shareLookupFailed(let message):
            String(localized: "The iCloud share could not be loaded: \(message)", comment: "Share error")
        case .persistentStoreUnavailable:
            String(localized: "The ledger's persistent store is unavailable.", comment: "Share error")
        case .privateStoreUnavailable:
            String(localized: "The private data store is unavailable, so no retained copy was created.", comment: "Share error")
        case .privateCopyFailed(let message):
            String(localized: "A private copy could not be saved. Sharing was not changed: \(message)", comment: "Share error")
        case .purgeFailed(let message, let retry):
            if retry.retainedLedgerID != nil {
                String(localized: "Your private copy was saved, but the shared iCloud data could not be removed. Retry to finish without creating another copy. \(message)", comment: "Share error")
            } else {
                String(localized: "The shared iCloud data could not be removed. Retry to leave the family. \(message)", comment: "Share error")
            }
        }
    }
}
