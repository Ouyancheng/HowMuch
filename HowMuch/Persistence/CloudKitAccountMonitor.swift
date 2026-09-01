import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class CloudKitAccountMonitor {
    var status: CKAccountStatus = .couldNotDetermine
    private var container: CKContainer?

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

    var isAvailable: Bool { status == .available }
    var isDetermining: Bool { status == .couldNotDetermine }
    var shouldShowBanner: Bool { !isDetermining && !isAvailable }

    init(identifier: String = PersistenceController.cloudKitContainerIdentifier) {
        guard CloudKitEntitlement.isPresent else {
            status = Self.statusWithoutCloudKitEntitlement()
            return
        }
        let container = CKContainer(identifier: identifier)
        self.container = container
        refresh()
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard let container else {
            status = Self.statusWithoutCloudKitEntitlement()
            return
        }
        container.accountStatus { [weak self] status, _ in
            Task { @MainActor in
                self?.status = status
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.status == .couldNotDetermine else { return }
            self.status = Self.statusWithoutCloudKitEntitlement()
        }
    }

    private static func statusWithoutCloudKitEntitlement() -> CKAccountStatus {
        FileManager.default.ubiquityIdentityToken == nil ? .noAccount : .available
    }
}
