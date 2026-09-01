import CoreData
import Foundation

enum ExpenseSearch {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func predicate(ledger: Ledger, text: String) -> NSPredicate {
        let term = normalized(text)
        guard !term.isEmpty else {
            return NSPredicate(format: "ledger == %@", ledger)
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "ledger == %@", ledger),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "merchant CONTAINS[cd] %@", term),
                NSPredicate(format: "note CONTAINS[cd] %@", term),
                NSPredicate(format: "category.name CONTAINS[cd] %@", term)
            ])
        ])
    }
}
