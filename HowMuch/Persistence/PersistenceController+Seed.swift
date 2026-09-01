import CoreData
import Foundation

extension PersistenceController {
    func bootstrapIfNeeded() {
        let request = Ledger.fetchRequest()
        request.predicate = NSPredicate(format: "kind == %d", LedgerKind.personal.rawValue)
        request.fetchLimit = 1
        do {
            let count = try viewContext.count(for: request)
            if count == 0 {
                _ = createLedger(
                    name: String(localized: "Personal", comment: "Default personal ledger name"),
                    kind: .personal,
                    reportingCurrency: CurrencyCatalog.localeCurrency
                )
                save()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func createLedger(name: String, kind: LedgerKind, reportingCurrency: String) -> Ledger {
        let ledger = Ledger(context: viewContext)
        ledger.name = name
        ledger.kind = kind.rawValue
        ledger.reportingCurrency = reportingCurrency
        if let privateStore {
            viewContext.assign(ledger, to: privateStore)
        }
        seedDefaults(for: ledger, currency: reportingCurrency)
        return ledger
    }

    func seedDefaults(for ledger: Ledger, currency: String) {
        for (index, template) in CategoryTemplate.defaults.enumerated() {
            let category = Category(context: viewContext)
            assign(category, toSameStoreAs: ledger)
            category.name = template.name
            category.symbolName = template.symbolName
            category.colorHex = template.colorHex
            category.sortOrder = Int16(index)
            category.ledger = ledger
        }

        let cash = PaymentMethod(context: viewContext)
        assign(cash, toSameStoreAs: ledger)
        cash.name = String(localized: "Cash", comment: "Default payment method")
        cash.kind = PaymentKind.cash.rawValue
        cash.billingCurrency = currency
        cash.ledger = ledger
    }

    func loadSampleData() {
        let ledger = createLedger(
            name: String(localized: "Personal", comment: "Default personal ledger name"),
            kind: .personal,
            reportingCurrency: "HKD"
        )
        let alipay = PaymentMethod(context: viewContext)
        alipay.name = "HKD Alipay"
        alipay.kind = PaymentKind.alipay.rawValue
        alipay.billingCurrency = "HKD"
        alipay.ledger = ledger

        let usdCard = PaymentMethod(context: viewContext)
        usdCard.name = "USD Credit Card"
        usdCard.kind = PaymentKind.creditCard.rawValue
        usdCard.billingCurrency = "USD"
        usdCard.ledger = ledger

        let dining = ledger.activeCategories.first { $0.wrappedName == String(localized: "Dining", comment: "Default category") }
            ?? ledger.activeCategories.first
        let transport = ledger.activeCategories.first { $0.wrappedName == String(localized: "Transport", comment: "Default category") }
            ?? ledger.activeCategories.last

        let dinner = Expense(context: viewContext)
        dinner.merchant = "Din Tai Fung"
        dinner.note = "Family dinner"
        dinner.occurredAt = Date().addingTimeInterval(-86_400)
        dinner.spendAmount = NSDecimalNumber(value: 88)
        dinner.spendCurrency = "CNY"
        dinner.chargedAmount = NSDecimalNumber(value: 96.5)
        dinner.chargedCurrency = "HKD"
        dinner.reportingAmount = NSDecimalNumber(value: 96.5)
        dinner.reportingCurrency = "HKD"
        dinner.ledger = ledger
        dinner.category = dining
        dinner.paymentMethod = alipay

        let taxi = Expense(context: viewContext)
        taxi.merchant = "Taxi"
        taxi.occurredAt = Date().addingTimeInterval(-3_600)
        taxi.spendAmount = NSDecimalNumber(value: 85)
        taxi.spendCurrency = "HKD"
        taxi.chargedAmount = NSDecimalNumber(value: 11.2)
        taxi.chargedCurrency = "USD"
        taxi.reportingAmount = NSDecimalNumber(value: 85)
        taxi.reportingCurrency = "HKD"
        taxi.ledger = ledger
        taxi.category = transport
        taxi.paymentMethod = usdCard

        save()
    }
}
