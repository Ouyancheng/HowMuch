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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
                .frame(minHeight: 0, maxHeight: .infinity)
        } content: {
            ActivityView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 560)
                .frame(minHeight: 0, maxHeight: .infinity)
        } detail: {
            InsightsView()
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .onAppear {
            LedgerSelection.bindSelection(appState, fallback: LedgerSelection.current(from: ledgers, appState: appState))
        }
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
        .hmMacListFillsColumn()
        .navigationTitle(String(localized: "Ledgers", comment: "Sidebar title"))
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
