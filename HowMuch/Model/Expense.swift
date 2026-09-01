import CoreData
import Foundation

@objc(Expense)
public final class Expense: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Expense> {
        NSFetchRequest<Expense>(entityName: "Expense")
    }

    @NSManaged public var uuid: UUID?
    @NSManaged public var occurredAt: Date?
    @NSManaged public var merchant: String?
    @NSManaged public var note: String?
    @NSManaged public var spendAmount: NSDecimalNumber?
    @NSManaged public var spendCurrency: String?
    @NSManaged public var chargedAmount: NSDecimalNumber?
    @NSManaged public var chargedCurrency: String?
    @NSManaged public var reportingAmount: NSDecimalNumber?
    @NSManaged public var reportingCurrency: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var createdByName: String?
    @NSManaged public var receiptContentType: String?
    @NSManaged public var receiptData: Data?
    @NSManaged public var receiptFileName: String?
    @NSManaged public var ledger: Ledger?
    @NSManaged public var category: Category?
    @NSManaged public var paymentMethod: PaymentMethod?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        let now = Date()
        uuid = UUID()
        createdAt = now
        updatedAt = now
        occurredAt = now
        merchant = ""
        note = ""
        createdByName = ""
        spendAmount = 0
        chargedAmount = 0
        reportingAmount = 0
        let currency = CurrencyCatalog.localeCurrency
        spendCurrency = currency
        chargedCurrency = currency
        reportingCurrency = currency
    }

    var wrappedID: UUID { uuid ?? UUID() }
    var wrappedOccurredAt: Date { occurredAt ?? Date() }
    var wrappedMerchant: String { merchant ?? "" }
    var wrappedNote: String { note ?? "" }
    var wrappedSpendAmount: Decimal { spendAmount as Decimal? ?? 0 }
    var wrappedChargedAmount: Decimal { chargedAmount as Decimal? ?? 0 }
    var wrappedReportingAmount: Decimal { reportingAmount as Decimal? ?? 0 }
    var wrappedSpendCurrency: String { spendCurrency ?? CurrencyCatalog.localeCurrency }
    var wrappedChargedCurrency: String { chargedCurrency ?? CurrencyCatalog.localeCurrency }
    var wrappedReportingCurrency: String { reportingCurrency ?? CurrencyCatalog.localeCurrency }

    var isDualCurrency: Bool {
        !MoneyMath.currenciesMatch(wrappedSpendCurrency, wrappedChargedCurrency)
    }

    var impliedRate: Decimal? {
        MoneyMath.impliedRate(spend: wrappedSpendAmount, charged: wrappedChargedAmount)
    }

    var hasReceipt: Bool {
        !(receiptData?.isEmpty ?? true)
    }

    func insightsReportingAmount(in reportingCurrency: String) -> Decimal {
        MoneyMath.insightsReportingAmount(
            spend: wrappedSpendAmount,
            spendCurrency: wrappedSpendCurrency,
            charged: wrappedChargedAmount,
            chargedCurrency: wrappedChargedCurrency,
            reportingCurrency: reportingCurrency,
            storedReporting: wrappedReportingAmount,
            storedReportingCurrency: wrappedReportingCurrency
        )
    }
    var wrappedReceiptFileName: String { receiptFileName ?? "" }

    var title: String {
        let merchant = wrappedMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !merchant.isEmpty { return merchant }
        return category?.wrappedName ?? String(localized: "Expense", comment: "Fallback expense title")
    }
}
