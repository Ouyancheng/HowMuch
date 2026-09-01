import CoreData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if persistence.isDataAvailable {
                LoadedRootView()
                    .id(persistence.stackGeneration)
            } else {
                DataLockedView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                persistence.invalidateLedgerAccess()
            }
        }
    }
}

struct DataAvailabilityGate<Content: View>: View {
    @EnvironmentObject private var persistence: PersistenceController
    @ViewBuilder let content: () -> Content

    var body: some View {
        if persistence.isDataAvailable {
            content()
                .id(persistence.stackGeneration)
        } else {
            DataLockedView()
        }
    }
}

struct DataLockedView: View {
    @EnvironmentObject private var persistence: PersistenceController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: persistence.isLocalOnly ? "externaldrive.badge.exclamationmark" : "lock.icloud")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(
                persistence.isLocalOnly
                    ? String(localized: "Local Data Unavailable", comment: "Unavailable data title")
                    : String(localized: "iCloud Data Locked", comment: "Unavailable data title")
            )
                .font(.title2.weight(.semibold))
            iCloudStatusBanner()
                .frame(maxWidth: 520)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("app.locked")
    }
}

private struct LoadedRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(AppState.self) private var appState
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ]
    )
    private var ledgers: FetchedResults<Ledger>

    private var selectedLedger: Ledger? {
        LedgerSelection.current(from: ledgers, appState: appState)
    }

    var body: some View {
        Group {
            #if os(macOS)
            SplitRootView()
            #else
            if sizeClass == .regular {
                SplitRootView()
            } else {
                TabRootView()
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: Bindable(appState).presentingNewExpense) {
            NavigationStack {
                ExpenseEditorView(expense: nil)
            }
            .environmentObject(persistence)
            .environment(appState)
        }
        .sheet(isPresented: Bindable(appState).presentingNewPersonal) {
            NavigationStack {
                NewLedgerView(kind: .personal)
            }
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
        }
        .sheet(isPresented: Bindable(appState).presentingNewHousehold) {
            NavigationStack {
                NewLedgerView(kind: .household)
            }
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
        }
        .sheet(isPresented: Bindable(appState).presentingLedgerSettings) {
            NavigationStack {
                if let selectedLedger {
                    LedgerDetailView(ledger: selectedLedger, showsCloseButton: true)
                }
            }
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
        }
        .sheet(isPresented: Bindable(appState).presentingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done", comment: "Button")) {
                                appState.presentingSettings = false
                            }
                        }
                    }
            }
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
        }
        .sheet(isPresented: Binding(
            get: { appState.expenseToEdit != nil },
            set: { if !$0 { appState.expenseToEdit = nil } }
        )) {
            if let expense = appState.expenseToEdit {
                NavigationStack {
                    ExpenseEditorView(expense: expense)
                }
                .environmentObject(persistence)
                .environment(appState)
            }
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.loaded")
        #if os(macOS)
        .sheet(isPresented: Bindable(appState).presentingSettings) {
            SettingsView()
                .environmentObject(persistence)
                .environment(appState)
                .environment(accountMonitor)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", comment: "Button")) {
                            appState.presentingSettings = false
                        }
                    }
                }
        }
        #endif
    }
}
