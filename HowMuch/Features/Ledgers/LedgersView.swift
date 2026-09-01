import CoreData
import SwiftUI

struct LedgersView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ],
        animation: .default
    )
    private var ledgers: FetchedResults<Ledger>

    var body: some View {
        List {
            Section(String(localized: "Personal", comment: "Section")) {
                ForEach(ledgers.filter(\.isPersonal), id: \.objectID) { ledger in
                    ledgerRow(ledger)
                }
                Button {
                    HowMuchPresenter.newPersonal(appState: appState, openWindow: openWindow)
                } label: {
                    Label(String(localized: "New Personal Ledger", comment: "List action"), systemImage: "plus")
                }
            }
            Section {
                ForEach(ledgers.filter(\.isHousehold), id: \.objectID) { ledger in
                    ledgerRow(ledger)
                }
                Button {
                    HowMuchPresenter.newHousehold(appState: appState, openWindow: openWindow)
                } label: {
                    Label(String(localized: "New Family Ledger", comment: "List action"), systemImage: "plus")
                }
            } header: {
                Text(String(localized: "Family", comment: "Section"))
            } footer: {
                Text(String(localized: "Family ledgers are shared with people you invite. Personal ledgers stay private."))
                    .hmWrappingFooter()
            }
        }
        .navigationTitle(String(localized: "Ledgers", comment: "Screen title"))
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            Text(String(localized: "Tap a ledger to show it in Activity. Use the info button for settings and family sharing."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        HowMuchPresenter.newPersonal(appState: appState, openWindow: openWindow)
                    } label: {
                        Label(String(localized: "New Personal Ledger", comment: "Toolbar"), systemImage: "person")
                    }
                    Button {
                        HowMuchPresenter.newHousehold(appState: appState, openWindow: openWindow)
                    } label: {
                        Label(String(localized: "New Family Ledger", comment: "Toolbar"), systemImage: "person.3")
                    }
                } label: {
                    Label(String(localized: "New Ledger", comment: "Toolbar"), systemImage: "plus")
                }
            }
        }
    }

    private func ledgerRow(_ ledger: Ledger) -> some View {
        let selected = appState.selectedLedgerID == ledger.wrappedID
        return HStack {
            LedgerRow(ledger: ledger)
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Button {
                appState.selectedLedgerID = ledger.wrappedID
                appState.presentingLedgerSettings = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Ledger Settings", comment: "Toolbar"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedLedgerID = ledger.wrappedID
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(String(localized: "Shows this ledger in Activity", comment: "Ledger selection"))
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
    }
}

struct LedgerSwitcherMenu: View {
    let ledgers: [Ledger]
    @Environment(AppState.self) private var appState

    var body: some View {
        let personal = ledgers.filter(\.isPersonal)
        let family = ledgers.filter(\.isHousehold)
        if !personal.isEmpty {
            Section(String(localized: "Personal", comment: "Section")) {
                ForEach(personal, id: \.objectID, content: button(for:))
            }
        }
        if !family.isEmpty {
            Section(String(localized: "Family", comment: "Section")) {
                ForEach(family, id: \.objectID, content: button(for:))
            }
        }
    }

    private func button(for ledger: Ledger) -> some View {
        Button {
            appState.selectedLedgerID = ledger.wrappedID
        } label: {
            Label {
                Text(ledger.wrappedName)
            } icon: {
                Image(systemName: appState.selectedLedgerID == ledger.wrappedID
                      ? "checkmark"
                      : ledger.ledgerKind.symbolName)
            }
        }
    }
}

struct LedgerDetailView: View {
    @ObservedObject var ledger: Ledger
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var persistence: PersistenceController
    @State private var name: String = ""
    @State private var reportingCurrency: String = "USD"
    @State private var mutationError: String?
    @State private var presentsCurrencyConfirmation = false
    @State private var dismissAfterCurrencyConfirmation = false

    private var isWritable: Bool {
        persistence.canWrite(ledger)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Name", comment: "Field"), text: $name)
                    .disabled(!isWritable)
                Picker(String(localized: "Reporting Currency", comment: "Field"), selection: $reportingCurrency) {
                    ForEach(CurrencyCatalog.featured, id: \.self) { code in
                        Text(CurrencyCatalog.displayName(for: code)).tag(code)
                    }
                }
                .accessibilityIdentifier("ledger.reporting-currency")
                .disabled(!isWritable)
                LabeledContent(String(localized: "Kind", comment: "Field"), value: ledger.ledgerKind.title)
            } header: {
                Text(String(localized: "Ledger", comment: "Section"))
            } footer: {
                if ledger.isPersonal {
                    Text(String(localized: "Personal ledgers stay private and sync across your own devices with iCloud."))
                        .hmWrappingFooter()
                } else {
                    Text(String(localized: "Family ledgers are shared with people you invite. Personal ledgers stay private."))
                        .hmWrappingFooter()
                }
            }

            Section {
                NavigationLink {
                    CategoriesEditorView(ledger: ledger)
                } label: {
                    Label(String(localized: "Categories", comment: "Link"), systemImage: "tag")
                }

                NavigationLink {
                    PaymentMethodsEditorView(ledger: ledger)
                } label: {
                    Label(String(localized: "Payment Methods", comment: "Link"), systemImage: "creditcard")
                }

                if ledger.isHousehold {
                    NavigationLink {
                        FamilySharingView(ledger: ledger)
                    } label: {
                        Label(String(localized: "Family Sharing", comment: "Link"), systemImage: "person.3")
                    }
                }
            }

            if !isWritable {
                Section {
                    Text(LedgerAccess.readOnlyExplanation)
                        .hmWrappingFooter()
                }
            }

            if let mutationError {
                Section {
                    Text(mutationError)
                        .foregroundStyle(.red)
                        .hmWrappingText()
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minHeight: 0)
        #endif
        .navigationTitle(ledger.wrappedName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button")) {
                        persistName()
                        if reportingCurrency != ledger.wrappedReportingCurrency {
                            dismissAfterCurrencyConfirmation = true
                            presentsCurrencyConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            name = ledger.wrappedName
            reportingCurrency = ledger.wrappedReportingCurrency
        }
        .onDisappear(perform: persistName)
        .task(id: name) {
            do {
                try await Task.sleep(for: .milliseconds(400))
                persistName()
            } catch {
                // Keystrokes cancel the prior pending save.
            }
        }
        .onChange(of: reportingCurrency) { _, newValue in
            if newValue != ledger.wrappedReportingCurrency {
                dismissAfterCurrencyConfirmation = false
                presentsCurrencyConfirmation = true
            }
        }
        .onChange(of: ledger.name) { oldValue, newValue in
            if name == (oldValue ?? "") {
                name = newValue ?? ""
            }
        }
        .onChange(of: ledger.reportingCurrency) { oldValue, newValue in
            if reportingCurrency == (oldValue ?? CurrencyCatalog.localeCurrency) {
                reportingCurrency = newValue ?? CurrencyCatalog.localeCurrency
            }
        }
        .confirmationDialog(
            String(localized: "Change Reporting Currency?", comment: "Currency confirmation title"),
            isPresented: $presentsCurrencyConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Keep Historical Values", comment: "Currency action")) {
                confirmCurrencyChange(mode: .keepHistoricalValues)
            }
            Button(String(localized: "Recalculate Stored Figures", comment: "Currency action")) {
                confirmCurrencyChange(mode: .recalculateStoredFigures)
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {
                reportingCurrency = ledger.wrappedReportingCurrency
                dismissAfterCurrencyConfirmation = false
            }
        } message: {
            Text(String(localized: "Recalculation uses the app's deterministic default exchange rates. The result is an approximation, not a historical market rate. Spend and charged amounts are never changed.", comment: "Currency confirmation explanation"))
        }
    }

    private func persistName() {
        guard isWritable else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ledger.wrappedName else { return }
        do {
            try persistence.updateLedger(
                ledger,
                name: trimmed,
                reportingCurrency: ledger.wrappedReportingCurrency
            )
            mutationError = nil
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private func confirmCurrencyChange(mode: ReportingCurrencyUpdateMode) {
        guard isWritable, reportingCurrency != ledger.wrappedReportingCurrency else { return }
        do {
            try persistence.updateReportingCurrency(
                for: ledger,
                to: reportingCurrency,
                mode: mode
            )
            mutationError = nil
            if dismissAfterCurrencyConfirmation {
                dismiss()
            }
            dismissAfterCurrencyConfirmation = false
        } catch {
            mutationError = error.localizedDescription
        }
    }
}

struct NewLedgerView: View {
    let kind: LedgerKind
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(AppState.self) private var appState
    @State private var name: String
    @State private var reportingCurrency = CurrencyCatalog.localeCurrency

    init(kind: LedgerKind) {
        self.kind = kind
        _name = State(initialValue: kind.title)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Name", comment: "Field"), text: $name)
                Picker(String(localized: "Reporting Currency", comment: "Field"), selection: $reportingCurrency) {
                    ForEach(CurrencyCatalog.featured, id: \.self) { code in
                        Text(CurrencyCatalog.displayName(for: code)).tag(code)
                    }
                }
            } footer: {
                Text(kind.newLedgerFooter)
                    .hmWrappingFooter()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind.newLedgerTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(kind.createLedgerTitle) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ledger = persistence.createLedger(
                        name: trimmed.isEmpty ? kind.title : trimmed,
                        kind: kind,
                        reportingCurrency: reportingCurrency
                    )
                    persistence.save()
                    appState.selectedLedgerID = ledger.uuid
                    dismiss()
                }
            }
        }
    }
}
