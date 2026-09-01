import CoreData
import Foundation

@objc(Ledger)
public final class Ledger: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Ledger> {
        NSFetchRequest<Ledger>(entityName: "Ledger")
    }

    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String?
    @NSManaged public var kind: Int16
    @NSManaged public var reportingCurrency: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var categories: Set<Category>?
    @NSManaged public var expenses: Set<Expense>?
    @NSManaged public var paymentMethods: Set<PaymentMethod>?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid = UUID()
        createdAt = Date()
        updatedAt = Date()
        name = ""
        kind = LedgerKind.personal.rawValue
        reportingCurrency = CurrencyCatalog.localeCurrency
    }

    var wrappedID: UUID { uuid ?? UUID() }
    var wrappedName: String { name ?? "" }
    var wrappedReportingCurrency: String { reportingCurrency ?? CurrencyCatalog.localeCurrency }
    var ledgerKind: LedgerKind { LedgerKind(rawValue: kind) ?? .personal }
    var isPersonal: Bool { ledgerKind == .personal }
    var isHousehold: Bool { ledgerKind == .household }

    var activeCategories: [Category] {
        (categories ?? []).filter { !$0.isArchived }.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.wrappedName.localizedCaseInsensitiveCompare($1.wrappedName) == .orderedAscending
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    var activePaymentMethods: [PaymentMethod] {
        (paymentMethods ?? []).filter { !$0.isArchived }.sorted {
            $0.wrappedName.localizedCaseInsensitiveCompare($1.wrappedName) == .orderedAscending
        }
    }
}
