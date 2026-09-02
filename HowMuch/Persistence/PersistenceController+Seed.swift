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
        _ = createLedger(
            name: String(localized: "Household", comment: "Sample family ledger name"),
            kind: .household,
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

        let cash = ledger.activePaymentMethods.first { $0.kind == PaymentKind.cash.rawValue }

        func category(_ name: String) -> Category? {
            ledger.activeCategories.first { $0.wrappedName == name }
        }

        addSampleExpense(
            merchant: "Din Tai Fung",
            note: "Family dinner",
            daysAgo: 1,
            spend: 88,
            spendCurrency: "CNY",
            charged: 96.5,
            chargedCurrency: "HKD",
            reporting: 96.5,
            ledger: ledger,
            category: category(String(localized: "Dining", comment: "Default category")),
            paymentMethod: alipay
        )
        addSampleExpense(
            merchant: "Taxi",
            daysAgo: 0,
            spend: 85,
            spendCurrency: "HKD",
            charged: 11.2,
            chargedCurrency: "USD",
            reporting: 85,
            ledger: ledger,
            category: category(String(localized: "Transport", comment: "Default category")),
            paymentMethod: usdCard
        )
        addSampleExpense(
            merchant: "City'super",
            daysAgo: 2,
            spend: 246.8,
            spendCurrency: "HKD",
            reporting: 246.8,
            ledger: ledger,
            category: category(String(localized: "Groceries", comment: "Default category")),
            paymentMethod: alipay
        )
        addSampleExpense(
            merchant: "MTR",
            daysAgo: 3,
            spend: 18.4,
            spendCurrency: "HKD",
            reporting: 18.4,
            ledger: ledger,
            category: category(String(localized: "Transport", comment: "Default category")),
            paymentMethod: cash
        )
        addSampleExpense(
            merchant: "Uniqlo",
            daysAgo: 4,
            spend: 399,
            spendCurrency: "HKD",
            reporting: 399,
            ledger: ledger,
            category: category(String(localized: "Shopping", comment: "Default category")),
            paymentMethod: alipay
        )
        addSampleExpense(
            merchant: "Netflix",
            daysAgo: 5,
            spend: 17.99,
            spendCurrency: "USD",
            charged: 140.3,
            chargedCurrency: "HKD",
            reporting: 140.3,
            ledger: ledger,
            category: category(String(localized: "Subscriptions", comment: "Default category")),
            paymentMethod: usdCard
        )

        save()
    }

    private func addSampleExpense(
        merchant: String,
        note: String? = nil,
        daysAgo: Int,
        spend: Double,
        spendCurrency: String,
        charged: Double? = nil,
        chargedCurrency: String? = nil,
        reporting: Double,
        ledger: Ledger,
        category: Category?,
        paymentMethod: PaymentMethod?
    ) {
        let expense = Expense(context: viewContext)
        expense.merchant = merchant
        expense.note = note
        expense.occurredAt = Self.sampleDate(daysAgo: daysAgo)
        expense.spendAmount = NSDecimalNumber(value: spend)
        expense.spendCurrency = spendCurrency
        expense.chargedAmount = NSDecimalNumber(value: charged ?? spend)
        expense.chargedCurrency = chargedCurrency ?? spendCurrency
        expense.reportingAmount = NSDecimalNumber(value: reporting)
        expense.reportingCurrency = "HKD"
        expense.ledger = ledger
        expense.category = category
        expense.paymentMethod = paymentMethod
    }

    private static func sampleDate(daysAgo: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let candidate = calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? now
        if let monthStart = calendar.dateInterval(of: .month, for: now)?.start, candidate < monthStart {
            return now.addingTimeInterval(-TimeInterval(max(daysAgo, 1) * 3600))
        }
        if daysAgo == 0 {
            return now.addingTimeInterval(-3_600)
        }
        return candidate.addingTimeInterval(18 * 3600)
    }
}
