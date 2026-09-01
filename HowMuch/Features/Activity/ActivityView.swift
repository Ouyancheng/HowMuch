import CoreData
import SwiftUI

struct ActivityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(CloudKitAccountMonitor.self) private var accountMonitor
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ],
        animation: .default
    )
    private var ledgers: FetchedResults<Ledger>

    @State private var searchText = ""

    private var ledger: Ledger? {
        LedgerSelection.current(from: ledgers, appState: appState)
    }

    var body: some View {
        Group {
            if let ledger {
                ExpenseList(ledger: ledger, searchText: searchText)
                    .id(ledger.objectID)
            } else {
                ContentUnavailableView(
                    String(localized: "No Expenses", comment: "Empty title"),
                    systemImage: "tray",
                    description: Text("Add your first spend to get started.")
                )
            }
        }
        .id(appState.selectedLedgerID)
        .frame(minHeight: 0, maxHeight: .infinity)
        .navigationTitle(ledger?.wrappedName ?? String(localized: "Activity", comment: "Screen title"))
        #if os(iOS)
        .toolbarTitleMenu {
            LedgerSwitcherMenu(ledgers: Array(ledgers))
        }
        #endif
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: String(localized: "Merchant or note", comment: "Search prompt")
        )
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                newExpenseButton
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }
            #endif
            ToolbarItem(placement: .automatic) {
                if let ledger {
                    Button {
                        HowMuchPresenter.ledgerSettings(for: ledger, appState: appState, openWindow: openWindow)
                    } label: {
                        Label(String(localized: "Ledger Settings", comment: "Toolbar"), systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel(String(localized: "Ledger Settings", comment: "Toolbar"))
                    .disabled(ledger.managedObjectContext == nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomChrome
        }
        .onAppear {
            LedgerSelection.bindSelection(appState, fallback: ledger)
        }
    }

    private var newExpenseButton: some View {
        Button {
            HowMuchPresenter.newExpense(appState: appState, openWindow: openWindow)
        } label: {
            Label(String(localized: "New Expense", comment: "Toolbar"), systemImage: "plus")
        }
        .accessibilityLabel(String(localized: "New Expense", comment: "Toolbar"))
    }

    #if os(iOS)
    private var newExpenseRoundButton: some View {
        Button {
            HowMuchPresenter.newExpense(appState: appState, openWindow: openWindow)
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(minWidth: 22, minHeight: 22)
        }
        .hmGlassRoundProminentButton()
        .accessibilityLabel(String(localized: "New Expense", comment: "Toolbar"))
    }
    #endif

    @ViewBuilder
    private var bottomChrome: some View {
        #if os(iOS)
        VStack(spacing: 10) {
            if showsiCloudBanner {
                iCloudStatusBanner()
                    .padding(.horizontal)
            }
            HStack {
                Spacer()
                newExpenseRoundButton
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        #else
        if showsiCloudBanner {
            iCloudStatusBanner()
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        #endif
    }

    private var showsiCloudBanner: Bool {
        accountMonitor.shouldShowBanner
            || (!persistence.cloudKitEnabled && !accountMonitor.isDetermining)
    }
}

private struct ExpenseList: View {
    @ObservedObject var ledger: Ledger
    var searchText: String
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var persistence: PersistenceController

    @FetchRequest private var expenses: FetchedResults<Expense>

    init(ledger: Ledger, searchText: String) {
        self.ledger = ledger
        self.searchText = searchText
        _expenses = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.occurredAt, ascending: false)],
            predicate: NSPredicate(format: "ledger == %@", ledger),
            animation: .default
        )
    }

    private var filtered: [Expense] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Array(expenses) }
        return expenses.filter {
            $0.wrappedMerchant.localizedCaseInsensitiveContains(term)
                || $0.wrappedNote.localizedCaseInsensitiveContains(term)
                || ($0.category?.wrappedName.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Expenses", comment: "Empty title"), systemImage: "tray")
            } description: {
                Text("Add your first spend to get started.")
            } actions: {
                Button {
                    HowMuchPresenter.newExpense(appState: appState, openWindow: openWindow)
                } label: {
                    Label(String(localized: "New Expense", comment: "Toolbar"), systemImage: "plus")
                }
                .hmGlassProminentButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filtered, id: \.objectID) { expense in
                    Button {
                        HowMuchPresenter.editExpense(expense, appState: appState, openWindow: openWindow)
                    } label: {
                        ExpenseRow(expense: expense)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(expense)
                        } label: {
                            Label(String(localized: "Delete", comment: "Button"), systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "Delete", comment: "Button"), role: .destructive) {
                            delete(expense)
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            .hmMacListFillsColumn()
            #endif
        }
    }

    private func delete(_ expense: Expense) {
        persistence.deleteExpense(expense)
    }
}

#if DEBUG
#Preview("Activity") {
    HowMuchPreview.wrap(
        NavigationStack {
            ActivityView()
        }
    )
    .frame(width: 400, height: 560)
}
#endif

