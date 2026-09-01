import SwiftUI

enum HowMuchWindowID {
    static let newExpense = "new-expense"
    static let editExpense = "edit-expense"
    static let ledgerSettings = "ledger-settings"
    static let newPersonal = "new-personal"
    static let newHousehold = "new-household"
}

@MainActor
enum HowMuchPresenter {
    static func newExpense(appState: AppState, openWindow: OpenWindowAction) {
        #if os(macOS)
        openWindow(id: HowMuchWindowID.newExpense)
        #else
        appState.presentingNewExpense = true
        #endif
    }

    static func editExpense(_ expense: Expense, appState: AppState, openWindow: OpenWindowAction) {
        #if os(macOS)
        openWindow(id: HowMuchWindowID.editExpense, value: expense.wrappedID)
        #else
        appState.expenseToEdit = expense
        #endif
    }

    static func ledgerSettings(for ledger: Ledger, appState: AppState, openWindow: OpenWindowAction) {
        #if os(macOS)
        openWindow(id: HowMuchWindowID.ledgerSettings, value: ledger.wrappedID)
        #else
        appState.presentingLedgerSettings = true
        #endif
    }

    static func newHousehold(appState: AppState, openWindow: OpenWindowAction) {
        newLedger(kind: .household, appState: appState, openWindow: openWindow)
    }

    static func newPersonal(appState: AppState, openWindow: OpenWindowAction) {
        newLedger(kind: .personal, appState: appState, openWindow: openWindow)
    }

    static func newLedger(kind: LedgerKind, appState: AppState, openWindow: OpenWindowAction) {
        #if os(macOS)
        openWindow(id: kind == .personal ? HowMuchWindowID.newPersonal : HowMuchWindowID.newHousehold)
        #else
        switch kind {
        case .personal:
            appState.presentingNewPersonal = true
        case .household:
            appState.presentingNewHousehold = true
        }
        #endif
    }
}
