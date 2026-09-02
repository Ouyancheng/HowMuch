import CoreData
import SwiftUI

struct ActivityView: View {
    var showsSplitSettingsButton = false

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
    @State private var debouncedSearchText = ""

    private var ledger: Ledger? {
        LedgerSelection.current(from: ledgers, appState: appState)
    }

    private var isWritable: Bool {
        ledger.map(persistence.canWrite) ?? false
    }

    var body: some View {
        Group {
            if let ledger {
                ExpenseList(ledger: ledger, searchText: debouncedSearchText)
                    .id("\(ledger.objectID.uriRepresentation().absoluteString)|\(debouncedSearchText)")
            } else {
                ContentUnavailableView(
                    String(localized: "No Expenses", comment: "Empty title"),
                    systemImage: "tray",
                    description: Text("Add your first spend to get started.")
                )
            }
        }
        .id(appState.selectedLedgerID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.screen")
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
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                debouncedSearchText = ExpenseSearch.normalized(searchText)
            } catch {
                // A newer search term superseded this task.
            }
        }
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
        .focusedValue(\.selectedLedgerIsWritable, isWritable)
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
        .disabled(!isWritable)
    }

    #if os(iOS)
    private var newExpenseRoundButton: some View {
        Button {
            HowMuchPresenter.newExpense(appState: appState, openWindow: openWindow)
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .hmGlassRoundProminentButton()
        .accessibilityLabel(String(localized: "New Expense", comment: "Toolbar"))
        .disabled(!isWritable)
    }

    @ViewBuilder
    private var splitSettingsButton: some View {
        if #available(iOS 26.0, *) {
            splitSettingsButtonLabel
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
        } else {
            splitSettingsButtonLabel
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }

    private var splitSettingsButtonLabel: some View {
        Button {
            appState.presentingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(String(localized: "Settings", comment: "Toolbar"))
        .accessibilityIdentifier("split.settings")
    }
    #endif

    @ViewBuilder
    private var bottomChrome: some View {
        #if os(iOS)
        VStack(spacing: 10) {
            if ledger != nil && !isWritable {
                Text(LedgerAccess.readOnlyExplanation)
                    .hmWrappingFooter()
                    .padding(.horizontal)
            }
            if showsiCloudBanner {
                iCloudStatusBanner()
                    .padding(.horizontal)
            }
            HStack {
                if showsSplitSettingsButton {
                    splitSettingsButton
                }
                Spacer()
                newExpenseRoundButton
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        #else
        VStack(spacing: 8) {
            if ledger != nil && !isWritable {
                Text(LedgerAccess.readOnlyExplanation)
                    .hmWrappingFooter()
                    .padding(.horizontal)
            }
            if showsiCloudBanner {
                iCloudStatusBanner()
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
        #endif
    }

    private var showsiCloudBanner: Bool {
        guard !PersistenceController.isUITesting, !PersistenceController.isCapturingScreenshots else {
            return false
        }
        return accountMonitor.shouldShowBanner
            || (!persistence.cloudKitEnabled && !accountMonitor.isDetermining)
            || persistence.shareError != nil
    }
}

private struct ExpenseList: View {
    @ObservedObject var ledger: Ledger
    var searchText: String
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var persistence: PersistenceController
    @State private var mutationError: String?

    @FetchRequest private var expenses: FetchedResults<Expense>

    init(ledger: Ledger, searchText: String) {
        self.ledger = ledger
        self.searchText = searchText
        _expenses = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.occurredAt, ascending: false)],
            predicate: ExpenseSearch.predicate(ledger: ledger, text: searchText),
            animation: .default
        )
    }

    var body: some View {
        Group {
            if expenses.isEmpty {
                if ExpenseSearch.normalized(searchText).isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Expenses", comment: "Empty title"), systemImage: "tray")
                    } description: {
                        Text(String(localized: "Add your first spend to get started."))
                    } actions: {
                        if persistence.canWrite(ledger) {
                            Button {
                                HowMuchPresenter.newExpense(appState: appState, openWindow: openWindow)
                            } label: {
                                Label(String(localized: "New Expense", comment: "Toolbar"), systemImage: "plus")
                            }
                            .hmGlassProminentButton()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(expenses, id: \.objectID) { expense in
                        if persistence.canWrite(ledger) {
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
                        } else {
                            ExpenseRow(expense: expense)
                        }
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                .hmMacListFillsColumn()
                #endif
                .accessibilityIdentifier("activity.screen")
            }
        }
        .alert(
            String(localized: "Expense Could Not Be Deleted", comment: "Alert"),
            isPresented: Binding(
                get: { mutationError != nil },
                set: { if !$0 { mutationError = nil } }
            )
        ) {
            Button(String(localized: "OK", comment: "Button"), role: .cancel) {}
        } message: {
            if let mutationError {
                Text(mutationError)
            }
        }
    }

    private func delete(_ expense: Expense) {
        do {
            try persistence.deleteExpense(expense)
        } catch {
            mutationError = error.localizedDescription
        }
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

