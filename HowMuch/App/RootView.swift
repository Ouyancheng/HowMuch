import CoreData
import SwiftUI

struct RootView: View {
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
    }
}
