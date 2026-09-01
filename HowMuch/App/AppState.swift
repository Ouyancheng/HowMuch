import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedLedgerID: UUID? {
        didSet {
            if let selectedLedgerID {
                UserDefaults.standard.set(selectedLedgerID.uuidString, forKey: Self.defaultsKey)
            }
        }
    }
    var presentingNewExpense = false
    var presentingNewPersonal = false
    var presentingNewHousehold = false
    var presentingLedgerSettings = false
    var expenseToEdit: Expense?

    private static let defaultsKey = "selectedLedgerID"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey), let uuid = UUID(uuidString: raw) {
            selectedLedgerID = uuid
        }
    }
}
