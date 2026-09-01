import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class CloudKitAccountMonitor {
    var status: CKAccountStatus = .couldNotDetermine
    private(set) var identity: CloudAccountIdentity = .resolving
    private(set) var generation = 0

    private var container: CKContainer?
    private var accountChangeObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var refreshNonce = UUID()

    var statusDescription: String {
        switch status {
        case .available:
            String(localized: "Signed In", comment: "iCloud account status")
        case .noAccount:
            String(localized: "Not Signed In", comment: "iCloud account status")
        case .restricted:
            String(localized: "Restricted", comment: "iCloud account status")
        case .temporarilyUnavailable:
            String(localized: "Temporarily Unavailable", comment: "iCloud account status")
        case .couldNotDetermine:
            String(localized: "Checking…", comment: "iCloud account status")
        @unknown default:
            String(localized: "Unknown", comment: "iCloud account status")
        }
    }

    var isAvailable: Bool {
        if case .available = identity { return true }
        return false
    }

    var isDetermining: Bool {
        if case .resolving = identity { return true }
        return false
    }

    var shouldShowBanner: Bool { !isDetermining && !isAvailable }

    init(identifier: String = PersistenceController.cloudKitContainerIdentifier) {
        if PersistenceController.isUITesting {
            status = .available
            identity = .available(fingerprint: "ui-testing")
            generation = 1
            return
        }
        guard CloudKitEntitlement.isPresent else {
            status = Self.statusWithoutCloudKitEntitlement()
            identity = .unavailable(
                String(localized: "This build is not configured for CloudKit.", comment: "iCloud status")
            )
            generation = 1
            return
        }
        let container = CKContainer(identifier: identifier)
        self.container = container
        refresh(invalidateIdentity: true)
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(invalidateIdentity: true)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            timeoutTask?.cancel()
            if let accountChangeObserver {
                NotificationCenter.default.removeObserver(accountChangeObserver)
            }
        }
    }

    func refresh(invalidateIdentity: Bool = false) {
        guard let container else {
            status = Self.statusWithoutCloudKitEntitlement()
            identity = .unavailable(
                String(localized: "This build is not configured for CloudKit.", comment: "iCloud status")
            )
            generation += 1
            return
        }

        timeoutTask?.cancel()
        let nonce = UUID()
        refreshNonce = nonce
        if invalidateIdentity {
            status = .couldNotDetermine
            identity = .resolving
            generation += 1
        }

        container.accountStatus { [weak self] status, error in
            Task { @MainActor in
                guard let self, self.refreshNonce == nonce else { return }
                self.status = status
                if let error {
                    self.timeoutTask?.cancel()
                    if invalidateIdentity || !self.hasVerifiedIdentity {
                        self.identity = .unavailable(Self.safeMessage(for: error))
                        self.generation += 1
                    }
                    return
                }
                self.resolveIdentity(
                    for: status,
                    container: container,
                    nonce: nonce,
                    invalidateIdentity: invalidateIdentity
                )
            }
        }

        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self, self.refreshNonce == nonce, self.identity == .resolving else { return }
            self.refreshNonce = UUID()
            self.identity = .unavailable(
                String(localized: "The iCloud account check timed out.", comment: "iCloud status")
            )
            self.generation += 1
        }
    }

    private func resolveIdentity(
        for status: CKAccountStatus,
        container: CKContainer,
        nonce: UUID,
        invalidateIdentity: Bool
    ) {
        switch status {
        case .available:
            // Do not interpret a nil ubiquity token while accountStatus is in
            // flight. CloudKit's record identity is resolved only after the
            // account is known to be available.
            container.fetchUserRecordID { [weak self] recordID, error in
                Task { @MainActor in
                    guard let self, self.refreshNonce == nonce else { return }
                    self.timeoutTask?.cancel()
                    if let error {
                        if invalidateIdentity || !self.hasVerifiedIdentity {
                            self.identity = .unavailable(Self.safeMessage(for: error))
                        } else {
                            return
                        }
                    } else if let recordName = recordID?.recordName {
                        self.identity = .available(
                            fingerprint: CloudIdentityFingerprint.make(
                                containerIdentifier: PersistenceController.cloudKitContainerIdentifier,
                                accountRecordName: recordName
                            )
                        )
                    } else {
                        if invalidateIdentity || !self.hasVerifiedIdentity {
                            self.identity = .unavailable(
                                String(localized: "The iCloud account identity is unavailable.", comment: "iCloud status")
                            )
                        } else {
                            return
                        }
                    }
                    self.generation += 1
                }
            }
        case .noAccount:
            timeoutTask?.cancel()
            identity = .signedOut
            generation += 1
        case .restricted:
            timeoutTask?.cancel()
            if invalidateIdentity || !hasVerifiedIdentity {
                identity = .unavailable(
                    String(localized: "iCloud access is restricted.", comment: "iCloud status")
                )
                generation += 1
            }
        case .temporarilyUnavailable:
            timeoutTask?.cancel()
            if invalidateIdentity || !hasVerifiedIdentity {
                identity = .unavailable(
                    String(localized: "iCloud is temporarily unavailable.", comment: "iCloud status")
                )
                generation += 1
            }
        case .couldNotDetermine:
            timeoutTask?.cancel()
            if invalidateIdentity || !hasVerifiedIdentity {
                identity = .unavailable(
                    String(localized: "The iCloud account could not be determined.", comment: "iCloud status")
                )
                generation += 1
            }
        @unknown default:
            timeoutTask?.cancel()
            if invalidateIdentity || !hasVerifiedIdentity {
                identity = .unavailable(
                    String(localized: "The iCloud account status is unknown.", comment: "iCloud status")
                )
                generation += 1
            }
        }
    }

    private var hasVerifiedIdentity: Bool {
        if case .available = identity { return true }
        return false
    }

    private static func safeMessage(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private static func statusWithoutCloudKitEntitlement() -> CKAccountStatus {
        FileManager.default.ubiquityIdentityToken == nil ? .noAccount : .available
    }
}
