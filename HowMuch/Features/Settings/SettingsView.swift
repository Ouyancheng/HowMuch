import CoreData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab(String(localized: "General", comment: "Settings tab"), systemImage: "gearshape") {
                SettingsGeneralPane()
            }
            Tab(String(localized: "iCloud", comment: "Settings tab"), systemImage: "icloud") {
                SettingsiCloudPane()
            }
            #if DEBUG
            Tab(String(localized: "Developer", comment: "Settings tab"), systemImage: "hammer") {
                SettingsDeveloperPane()
            }
            #endif
        }
        .frame(minWidth: 520, minHeight: 360)
        #else
        Form {
            SettingsiCloudSection()
            SettingsPersonalLedgersSection()
            SettingsAboutSection()
            #if DEBUG
            SettingsDeveloperSection()
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Settings", comment: "Screen title"))
        #endif
    }
}

struct SettingsGeneralPane: View {
    var body: some View {
        Form {
            SettingsAboutSection()
            SettingsPersonalLedgersSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
    }
}

struct SettingsiCloudPane: View {
    var body: some View {
        Form {
            SettingsiCloudSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
    }
}

#if DEBUG
struct SettingsDeveloperPane: View {
    var body: some View {
        Form {
            SettingsDeveloperSection()
        }
        .formStyle(.grouped)
        .frame(minWidth: 480)
        .padding(.top, 8)
    }
}
#endif

private struct SettingsAboutSection: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        Section {
            HMSettingsValueRow(
                title: "HowMuch",
                value: version
            )
        } header: {
            Text("About")
        } footer: {
            Text("Spend tracking for individuals and families, using your Apple ID.")
                .hmWrappingFooter()
        }
    }
}

private struct SettingsPersonalLedgersSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)],
        predicate: NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
    )
    private var personalLedgers: FetchedResults<Ledger>

    var body: some View {
        Section {
            ForEach(personalLedgers, id: \.objectID) { ledger in
                #if os(macOS)
                Button {
                    HowMuchPresenter.ledgerSettings(for: ledger, appState: appState, openWindow: openWindow)
                } label: {
                    HStack {
                        Label(ledger.wrappedName, systemImage: ledger.ledgerKind.symbolName)
                        Spacer(minLength: 12)
                        Text(ledger.wrappedReportingCurrency)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(ledger.managedObjectContext == nil)
                #else
                NavigationLink {
                    LedgerDetailView(ledger: ledger)
                } label: {
                    Label(ledger.wrappedName, systemImage: ledger.ledgerKind.symbolName)
                }
                #endif
            }

            Button {
                HowMuchPresenter.newPersonal(appState: appState, openWindow: openWindow)
            } label: {
                Label(String(localized: "New Personal Ledger", comment: "Settings action"), systemImage: "plus")
            }
        } header: {
            Text("Personal Ledgers")
        } footer: {
            Text("Personal ledgers stay private and sync across your own devices with iCloud.")
                .hmWrappingFooter()
        }
    }
}

private struct SettingsiCloudSection: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor

    private var showsStatusBanner: Bool {
        accountMonitor.shouldShowBanner
            || (!persistence.cloudKitEnabled && !accountMonitor.isDetermining)
    }

    var body: some View {
        Section {
            if showsStatusBanner {
                iCloudStatusBanner()
            }
            HMSettingsValueRow(
                title: String(localized: "Account", comment: "Field"),
                value: accountMonitor.statusDescription
            )
            HMSettingsValueRow(
                title: String(localized: "iCloud Sync", comment: "Field"),
                value: persistence.cloudKitEnabled
                    ? String(localized: "On", comment: "Toggle on")
                    : String(localized: "Off", comment: "Toggle off")
            )
        } header: {
            Text("iCloud")
        } footer: {
            if !showsStatusBanner {
                Text(persistence.iCloudSyncDetail)
                    .hmWrappingFooter()
            }
        }
        .onAppear {
            accountMonitor.refresh()
        }
    }
}

#if DEBUG
private struct SettingsDeveloperSection: View {
    @EnvironmentObject private var persistence: PersistenceController
    @State private var schemaMessage: String?

    var body: some View {
        Section {
            Button("Initialize CloudKit Schema") {
                guard persistence.cloudKitEnabled else {
                    schemaMessage = String(localized: "CloudKit is off, so the schema cannot be initialized.", comment: "Debug")
                    return
                }
                do {
                    try persistence.initializeCloudKitSchema()
                    schemaMessage = String(localized: "CloudKit schema initialized.", comment: "Debug")
                } catch {
                    schemaMessage = error.localizedDescription
                }
            }
            .disabled(!persistence.cloudKitEnabled)

            if let schemaMessage {
                Text(schemaMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
            }
            if let loadError = persistence.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .hmWrappingText()
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Schema initialization needs a CloudKit-signed build.")
                .hmWrappingFooter()
        }
    }
}
#endif

#if DEBUG
#Preview("Settings") {
    HowMuchPreview.wrap(SettingsView())
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
}

#if os(macOS)
#Preview("Settings iCloud") {
    HowMuchPreview.wrap(SettingsiCloudPane())
        .frame(width: 560, height: 420)
}
#endif
#endif
