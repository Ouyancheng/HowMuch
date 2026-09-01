import CoreData
import SwiftUI

@MainActor
enum LedgerSelection {
    static func current(from ledgers: FetchedResults<Ledger>, appState: AppState) -> Ledger? {
        if let id = appState.selectedLedgerID, let match = ledgers.first(where: { $0.uuid == id }) {
            return match
        }
        return ledgers.first(where: \.isPersonal) ?? ledgers.first
    }

    static func bindSelection(_ appState: AppState, fallback: Ledger?) {
        if appState.selectedLedgerID == nil, let fallback {
            appState.selectedLedgerID = fallback.uuid
        }
    }
}
