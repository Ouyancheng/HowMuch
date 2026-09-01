import CoreData
import SwiftUI

struct SplitRootView: View {
    @Environment(AppState.self) private var appState
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ],
        animation: .default
    )
    private var ledgers: FetchedResults<Ledger>

    var body: some View {
        NavigationSplitView {
            LedgerSidebar(ledgers: Array(ledgers))
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 300)
                .frame(minHeight: 0, maxHeight: .infinity)
        } content: {
            activityColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 390, max: 560)
                .frame(minHeight: 0, maxHeight: .infinity)
        } detail: {
            InsightsView()
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        #else
        .frame(minHeight: 0, maxHeight: .infinity)
        #endif
        .onAppear {
            LedgerSelection.bindSelection(appState, fallback: LedgerSelection.current(from: ledgers, appState: appState))
        }
    }

    @ViewBuilder
    private var activityColumn: some View {
        #if os(iOS)
        // RootView presents SplitRootView only for regular-width iOS layouts.
        // Child split columns can report a compact size class when collapsed,
        // so do not use the column-local environment to hide this action.
        ActivityView(showsSplitSettingsButton: true)
        #else
        ActivityView()
        #endif
    }
}

struct LedgerSidebar: View {
    let ledgers: [Ledger]
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var personalLedgers: [Ledger] { ledgers.filter(\.isPersonal) }
    private var householdLedgers: [Ledger] { ledgers.filter(\.isHousehold) }

    var body: some View {
        List {
            Section(String(localized: "Personal", comment: "Sidebar section")) {
                ForEach(personalLedgers, id: \.objectID) { ledger in
                    ledgerButton(ledger)
                }
                Button {
                    HowMuchPresenter.newPersonal(appState: appState, openWindow: openWindow)
                } label: {
                    Label(String(localized: "New Personal Ledger", comment: "Sidebar action"), systemImage: "plus")
                }
            }
            Section(String(localized: "Family", comment: "Sidebar section")) {
                ForEach(householdLedgers, id: \.objectID) { ledger in
                    ledgerButton(ledger)
                }
                Button {
                    HowMuchPresenter.newHousehold(appState: appState, openWindow: openWindow)
                } label: {
                    Label(String(localized: "New Family Ledger", comment: "Sidebar action"), systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.navigation")
        .hmMacListFillsColumn()
        .navigationTitle(String(localized: "Ledgers", comment: "Sidebar title"))
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    appState.presentingSettings = true
                } label: {
                    Label(String(localized: "Settings", comment: "Sidebar action"), systemImage: "gear")
                }
                .accessibilityIdentifier("sidebar.settings")
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                Spacer()
            }
            .padding(.horizontal)
            .background(.bar)
        }
        #endif
    }

    private func ledgerButton(_ ledger: Ledger) -> some View {
        let selected = appState.selectedLedgerID == ledger.wrappedID
        return Button {
            appState.selectedLedgerID = ledger.wrappedID
        } label: {
            LedgerRow(ledger: ledger)
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LedgerRow: View {
    @ObservedObject var ledger: Ledger

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(ledger.wrappedName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(ledger.wrappedReportingCurrency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ledger.currency")
            }
        } icon: {
            Image(systemName: ledger.ledgerKind.symbolName)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(ledger.wrappedName)
        .accessibilityValue(ledger.ledgerKind.title)
    }
}

#if DEBUG
#Preview("Mac Window") {
    HowMuchPreview.wrap(SplitRootView())
        .frame(width: 920, height: 560)
}
#endif
