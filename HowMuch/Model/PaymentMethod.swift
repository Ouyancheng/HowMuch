import CoreData
import Foundation

@objc(PaymentMethod)
public final class PaymentMethod: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PaymentMethod> {
        NSFetchRequest<PaymentMethod>(entityName: "PaymentMethod")
    }

    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String?
    @NSManaged public var billingCurrency: String?
    @NSManaged public var kind: Int16
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var ledger: Ledger?
    @NSManaged public var expenses: Set<Expense>?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid = UUID()
        createdAt = Date()
        name = ""
        billingCurrency = CurrencyCatalog.localeCurrency
        kind = PaymentKind.cash.rawValue
        isArchived = false
    }

    var wrappedName: String { name ?? "" }
    var wrappedBillingCurrency: String { billingCurrency ?? CurrencyCatalog.localeCurrency }
    var paymentKind: PaymentKind { PaymentKind(rawValue: kind) ?? .other }
    var canBeRemoved: Bool { paymentKind != .cash }
}
