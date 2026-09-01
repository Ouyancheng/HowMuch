import CoreData
import SwiftUI

struct MacEditorContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
        }
        .frame(minWidth: 360, minHeight: 280)
    }
}

struct ExpenseWindowHost: View {
    let expenseID: UUID?

    @FetchRequest private var expenses: FetchedResults<Expense>

    init(expenseID: UUID?) {
        self.expenseID = expenseID
        if let expenseID {
            _expenses = FetchRequest(
                sortDescriptors: [],
                predicate: NSPredicate(format: "uuid == %@", expenseID as NSUUID),
                animation: nil
            )
        } else {
            _expenses = FetchRequest(
                sortDescriptors: [],
                predicate: NSPredicate(value: false),
                animation: nil
            )
        }
    }

    var body: some View {
        if let expense = expenses.first {
            ExpenseEditorView(expense: expense)
        } else {
            ContentUnavailableView(
                String(localized: "Expense", comment: "Fallback expense title"),
                systemImage: "creditcard"
            )
        }
    }
}

struct LedgerSettingsWindowHost: View {
    let ledgerID: UUID?

    @FetchRequest private var ledgers: FetchedResults<Ledger>

    init(ledgerID: UUID?) {
        self.ledgerID = ledgerID
        if let ledgerID {
            _ledgers = FetchRequest(
                sortDescriptors: [],
                predicate: NSPredicate(format: "uuid == %@", ledgerID as NSUUID),
                animation: nil
            )
        } else {
            _ledgers = FetchRequest(
                sortDescriptors: [],
                predicate: NSPredicate(value: false),
                animation: nil
            )
        }
    }

    var body: some View {
        if let ledger = ledgers.first {
            LedgerDetailView(ledger: ledger, showsCloseButton: true)
        } else {
            ContentUnavailableView(
                String(localized: "Ledgers", comment: "Screen title"),
                systemImage: "books.vertical"
            )
        }
    }
}
