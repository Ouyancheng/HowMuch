import SwiftUI

struct iCloudStatusBanner: View {
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor
    @EnvironmentObject private var persistence: PersistenceController

    var body: some View {
        if accountMonitor.isDetermining {
            EmptyView()
        } else if !accountMonitor.isAvailable {
            banner(
                symbol: "icloud.slash",
                title: String(localized: "No iCloud Account", comment: "Banner title"),
                message: String(localized: "Sign in to iCloud in Settings to sync across your devices and share with family. Your personal ledger still works on this device.")
            )
        } else if !persistence.cloudKitEnabled {
            banner(
                symbol: "exclamationmark.icloud",
                title: String(localized: "iCloud Sync Off", comment: "Banner title"),
                message: persistence.iCloudSyncDetail
            )
        }
    }

    private func banner(symbol: String, title: String, message: String) -> some View {
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
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .hmGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
