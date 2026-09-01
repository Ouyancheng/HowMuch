import SwiftUI

struct iCloudStatusBanner: View {
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor
    @EnvironmentObject private var persistence: PersistenceController

    var body: some View {
        if let shareError = persistence.shareError {
            banner(
                symbol: "person.icloud",
                title: String(localized: "Invitation Needs Attention", comment: "Banner title"),
                message: shareError,
                offersRetry: persistence.hasPendingShareInvitation,
                retriesShareInvitation: true
            )
        } else if persistence.loadState == .failed {
            banner(
                symbol: "exclamationmark.icloud",
                title: persistence.isLocalOnly
                    ? String(localized: "Local Data Could Not Load", comment: "Banner title")
                    : String(localized: "iCloud Data Could Not Load", comment: "Banner title"),
                message: persistence.loadError
                    ?? String(localized: "The data store could not be loaded."),
                offersRetry: true
            )
        } else if persistence.isLocalOnly {
            banner(
                symbol: "icloud.slash",
                title: String(localized: "iCloud Sync Off", comment: "Banner title"),
                message: persistence.iCloudSyncDetail
            )
        } else if accountMonitor.isDetermining {
            banner(
                symbol: "icloud.and.arrow.down",
                title: String(localized: "Checking iCloud", comment: "Banner title"),
                message: persistence.isDataAvailable
                    ? String(localized: "You can keep using the app. Sync stays off until your iCloud account is verified.", comment: "Banner message")
                    : String(localized: "Checking whether iCloud sync is available.", comment: "Banner message")
            )
        } else if !accountMonitor.isAvailable {
            banner(
                symbol: "icloud.slash",
                title: String(localized: "No iCloud Account", comment: "Banner title"),
                message: persistence.loadError
                    ?? PlatformCopy.signInToICloud
            )
        } else if !persistence.cloudKitEnabled {
            banner(
                symbol: "exclamationmark.icloud",
                title: String(localized: "iCloud Sync Off", comment: "Banner title"),
                message: persistence.iCloudSyncDetail
            )
        } else if persistence.loadState == .loading {
            banner(
                symbol: "icloud.and.arrow.down",
                title: String(localized: "Loading iCloud Data", comment: "Banner title"),
                message: String(localized: "Opening the private and shared stores for this account.")
            )
        } else if let diagnostic = persistence.diagnostic {
            banner(
                symbol: "exclamationmark.icloud",
                title: String(localized: "iCloud Sync Needs Attention", comment: "Banner title"),
                message: diagnostic.message,
                offersRetry: true
            )
        }
    }

    private func banner(
        symbol: String,
        title: String,
        message: String,
        offersRetry: Bool = false,
        retriesShareInvitation: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
                if offersRetry {
                    Button(String(localized: "Retry", comment: "iCloud action")) {
                        Task {
                            if retriesShareInvitation {
                                persistence.retryPendingShareInvitation()
                            } else if !persistence.isLocalOnly,
                               persistence.currentAccountFingerprint == nil {
                                accountMonitor.refresh()
                            } else {
                                await persistence.retryStoreLoad()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .hmGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
