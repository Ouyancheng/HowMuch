import Foundation

enum LedgerKind: Int16, CaseIterable, Identifiable, Sendable {
    case personal = 0
    case household = 1

    var id: Int16 { rawValue }

    var title: String {
        switch self {
        case .personal:
            String(localized: "Personal", comment: "Ledger kind")
        case .household:
            String(localized: "Family", comment: "Ledger kind")
        }
    }

    var symbolName: String {
        switch self {
        case .personal: "person"
        case .household: "person.3"
        }
    }

    var newLedgerTitle: String {
        switch self {
        case .personal:
            String(localized: "New Personal Ledger", comment: "Screen title")
        case .household:
            String(localized: "New Family Ledger", comment: "Screen title")
        }
    }

    var createLedgerTitle: String {
        switch self {
        case .personal:
            String(localized: "Create Personal Ledger", comment: "Button")
        case .household:
            String(localized: "Create Family Ledger", comment: "Button")
        }
    }

    var newLedgerFooter: String {
        switch self {
        case .personal:
            String(localized: "Personal ledgers stay private and sync across your own devices with iCloud.")
        case .household:
            String(localized: "Invite people with their Apple Account via Messages or Mail after you create the ledger.")
        }
    }
}
