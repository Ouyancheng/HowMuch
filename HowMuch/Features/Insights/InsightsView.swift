import Accessibility
import Charts
import CoreData
import SwiftUI

enum InsightsRange: String, CaseIterable, Identifiable {
    case month
    case thirtyDays
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: String(localized: "This Month", comment: "Insights range")
        case .thirtyDays: String(localized: "Last 30 Days", comment: "Insights range")
        case .all: String(localized: "All Time", comment: "Insights range")
        }
    }

    func dateInterval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .month:
            return calendar.dateInterval(of: .month, for: now)
        case .thirtyDays:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -29, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else {
                return nil
            }
            return DateInterval(start: start, end: end)
        case .all:
            return nil
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let interval = dateInterval(now: now, calendar: calendar) else { return true }
        return date >= interval.start && date < interval.end
    }

    func predicate(for ledger: Ledger, now: Date = Date(), calendar: Calendar = .current) -> NSPredicate {
        guard let interval = dateInterval(now: now, calendar: calendar) else {
            return NSPredicate(format: "ledger == %@", ledger)
        }
        return NSPredicate(
            format: "ledger == %@ AND occurredAt >= %@ AND occurredAt < %@",
            ledger,
            interval.start as NSDate,
            interval.end as NSDate
        )
    }
}

struct InsightsView: View {
    @Environment(AppState.self) private var appState
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ]
    )
    private var ledgers: FetchedResults<Ledger>

    @State private var range: InsightsRange = .month

    private var ledger: Ledger? {
        LedgerSelection.current(from: ledgers, appState: appState)
    }

    var body: some View {
        Group {
            if let ledger {
                InsightsContent(ledger: ledger, range: $range)
                    .id("\(ledger.objectID.uriRepresentation().absoluteString)|\(range.rawValue)")
            } else {
                ContentUnavailableView(
                    String(localized: "Insights", comment: "Screen title"),
                    systemImage: "chart.bar",
                    description: Text("Add expenses to see totals by category and currency.")
                )
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .navigationTitle(String(localized: "Insights", comment: "Screen title"))
        #if os(iOS)
        .toolbarTitleMenu {
            LedgerSwitcherMenu(ledgers: Array(ledgers))
        }
        #endif
    }
}

private struct InsightsRangeControl: View {
    @Binding var range: InsightsRange
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                rangeMenu
            } else {
                ViewThatFits(in: .horizontal) {
                    HMGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            rangeButtons
                        }
                    }
                    rangeMenu
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Range", comment: "Insights"))
        .accessibilityIdentifier("insights.range")
    }

    @ViewBuilder
    private var rangeButtons: some View {
        ForEach(InsightsRange.allCases) { item in
            Button {
                range = item
            } label: {
                Text(item.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
            }
            .hmGlassChoiceButton(isSelected: range == item)
            .accessibilityAddTraits(range == item ? .isSelected : [])
        }
    }

    private var rangeMenu: some View {
        Picker(String(localized: "Range", comment: "Insights"), selection: $range) {
            ForEach(InsightsRange.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InsightsExpenseInput: Equatable, Sendable {
    let categoryName: String
    let categorySymbol: String
    let categoryColorHex: String
    let spendAmount: Decimal
    let spendCurrency: String
    let chargedAmount: Decimal
    let chargedCurrency: String
    let storedReportingAmount: Decimal
    let storedReportingCurrency: String

    init(expense: Expense) {
        categoryName = expense.category?.wrappedName ?? String(localized: "Other", comment: "Default category")
        categorySymbol = expense.category?.wrappedSymbolName ?? "tag"
        categoryColorHex = expense.category?.wrappedColorHex ?? "64748B"
        spendAmount = expense.wrappedSpendAmount
        spendCurrency = expense.wrappedSpendCurrency
        chargedAmount = expense.wrappedChargedAmount
        chargedCurrency = expense.wrappedChargedCurrency
        storedReportingAmount = expense.wrappedReportingAmount
        storedReportingCurrency = expense.wrappedReportingCurrency
    }

    init(
        categoryName: String,
        categorySymbol: String = "tag",
        categoryColorHex: String = "64748B",
        spendAmount: Decimal,
        spendCurrency: String,
        chargedAmount: Decimal,
        chargedCurrency: String,
        storedReportingAmount: Decimal,
        storedReportingCurrency: String
    ) {
        self.categoryName = categoryName
        self.categorySymbol = categorySymbol
        self.categoryColorHex = categoryColorHex
        self.spendAmount = spendAmount
        self.spendCurrency = spendCurrency
        self.chargedAmount = chargedAmount
        self.chargedCurrency = chargedCurrency
        self.storedReportingAmount = storedReportingAmount
        self.storedReportingCurrency = storedReportingCurrency
    }
}

struct InsightsCategoryTotal: Equatable, Sendable {
    let name: String
    let symbol: String
    let colorHex: String
    let total: Decimal
}

struct InsightsCurrencyTotal: Equatable, Sendable {
    let code: String
    let total: Decimal
}

struct InsightsSnapshot: Equatable, Sendable {
    let reportingCode: String
    let isEmpty: Bool
    let reportingTotal: Decimal
    let byCategory: [InsightsCategoryTotal]
    let bySpend: [InsightsCurrencyTotal]
    let byCharged: [InsightsCurrencyTotal]

    init(expenses: [InsightsExpenseInput], reportingCode: String) {
        self.reportingCode = reportingCode
        isEmpty = expenses.isEmpty

        var total: Decimal = 0
        var categories: [String: (symbol: String, colorHex: String, total: Decimal)] = [:]
        var spend: [String: Decimal] = [:]
        var charged: [String: Decimal] = [:]
        for expense in expenses {
            let converted = MoneyMath.insightsReportingAmount(
                spend: expense.spendAmount,
                spendCurrency: expense.spendCurrency,
                charged: expense.chargedAmount,
                chargedCurrency: expense.chargedCurrency,
                reportingCurrency: reportingCode,
                storedReporting: expense.storedReportingAmount,
                storedReportingCurrency: expense.storedReportingCurrency
            )
            total += converted
            let current = categories[expense.categoryName]
            categories[expense.categoryName] = (
                expense.categorySymbol,
                expense.categoryColorHex,
                (current?.total ?? 0) + converted
            )
            spend[expense.spendCurrency, default: 0] += expense.spendAmount
            charged[expense.chargedCurrency, default: 0] += expense.chargedAmount
        }
        reportingTotal = total
        byCategory = categories
            .map {
                InsightsCategoryTotal(
                    name: $0.key,
                    symbol: $0.value.symbol,
                    colorHex: $0.value.colorHex,
                    total: $0.value.total
                )
            }
            .sorted { $0.total > $1.total }
        bySpend = spend.map { InsightsCurrencyTotal(code: $0.key, total: $0.value) }
            .sorted { $0.code < $1.code }
        byCharged = charged.map { InsightsCurrencyTotal(code: $0.key, total: $0.value) }
            .sorted { $0.code < $1.code }
    }
}

private struct InsightsContent: View {
    @ObservedObject var ledger: Ledger
    @Binding var range: InsightsRange
    @FetchRequest private var expenses: FetchedResults<Expense>
    @ScaledMetric(relativeTo: .body) private var chartRowHeight = 36

    init(ledger: Ledger, range: Binding<InsightsRange>) {
        self.ledger = ledger
        _range = range
        _expenses = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.occurredAt, ascending: false)],
            predicate: range.wrappedValue.predicate(for: ledger),
            animation: .default
        )
    }

    var body: some View {
        let snapshot = InsightsSnapshot(
            expenses: expenses.map(InsightsExpenseInput.init),
            reportingCode: ledger.wrappedReportingCurrency
        )
        Form {
            Section {
                InsightsRangeControl(range: $range)

                VStack(alignment: .leading, spacing: 6) {
                    Text(range == .month
                         ? String(localized: "This Month’s Spend", comment: "Insights headline")
                         : range.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(CurrencyCatalog.format(snapshot.reportingTotal, code: snapshot.reportingCode))
                        .font(.largeTitle.bold().monospacedDigit())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(String(
                            localized: "Total \(CurrencyCatalog.format(snapshot.reportingTotal, code: snapshot.reportingCode))",
                            comment: "VoiceOver insights total"
                        ))
                    Text(String(localized: "All currencies, in \(snapshot.reportingCode). Default rates are used when an expense was not entered in this currency."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .hmWrappingText()
                }
                .padding(.vertical, 4)
            }

            if snapshot.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Expenses", comment: "Empty title"),
                    systemImage: "chart.bar",
                    description: Text("Add expenses to see totals by category and currency.")
                )
            } else {
                Section {
                    InsightsCategoryChart(snapshot: snapshot)
                        .frame(height: max(chartRowHeight * 4.5, CGFloat(snapshot.byCategory.count) * chartRowHeight))
                } header: {
                    Text(String(localized: "By Category", comment: "Insights section"))
                } footer: {
                    Text(String(localized: "Totals in \(snapshot.reportingCode).", comment: "Insights chart footer"))
                        .hmWrappingFooter()
                }

                totalsSection(
                    title: String(localized: "By Spend Currency", comment: "Insights section"),
                    subtitle: String(localized: "What you consumed, with an approximate \(snapshot.reportingCode) equivalent.", comment: "Insights subtitle"),
                    rows: snapshot.bySpend,
                    reportingCode: snapshot.reportingCode
                )

                totalsSection(
                    title: String(localized: "By Charged Currency", comment: "Insights section"),
                    subtitle: String(localized: "What left the wallet, with an approximate \(snapshot.reportingCode) equivalent.", comment: "Insights subtitle"),
                    rows: snapshot.byCharged,
                    reportingCode: snapshot.reportingCode
                )
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .hmMacListFillsColumn()
        #endif
    }

    private func totalsSection(
        title: String,
        subtitle: String,
        rows: [InsightsCurrencyTotal],
        reportingCode: String
    ) -> some View {
        Section {
            ForEach(rows, id: \.code) { row in
                LabeledContent(row.code) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CurrencyCatalog.format(row.total, code: row.code))
                            .monospacedDigit()
                            .accessibilityLabel(String(
                                localized: "Amount \(CurrencyCatalog.format(row.total, code: row.code))",
                                comment: "VoiceOver currency amount"
                            ))
                        if let converted = DefaultFXRates.convert(row.total, from: row.code, to: reportingCode),
                           !MoneyMath.currenciesMatch(row.code, reportingCode) {
                            Text("≈ \(CurrencyCatalog.format(converted, code: reportingCode))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityLabel(String(
                                    localized: "Approximately \(CurrencyCatalog.format(converted, code: reportingCode))",
                                    comment: "VoiceOver converted amount"
                                ))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(title)
        } footer: {
            Text(subtitle)
                .hmWrappingFooter()
        }
    }
}

private struct InsightsCategoryChart: View, AXChartDescriptorRepresentable {
    let snapshot: InsightsSnapshot

    var body: some View {
        Chart(snapshot.byCategory, id: \.name) { item in
            BarMark(
                x: .value(String(localized: "Total", comment: "Chart axis"), item.total),
                y: .value(String(localized: "Category", comment: "Chart axis"), item.name)
            )
            .foregroundStyle(Color(hex: item.colorHex))
            .accessibilityLabel(item.name)
            .accessibilityValue(CurrencyCatalog.format(item.total, code: snapshot.reportingCode))
        }
        .accessibilityChartDescriptor(self)
        .accessibilityLabel(String(localized: "By Category", comment: "Insights section"))
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let maximum = snapshot.byCategory
            .map { NSDecimalNumber(decimal: $0.total).doubleValue }
            .max() ?? 0
        let valueAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Total", comment: "Chart axis"),
            range: 0...max(maximum, 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                CurrencyCatalog.format(Decimal(value), code: snapshot.reportingCode)
            }
        )
        let categoryAxis = AXCategoricalDataAxisDescriptor(
            title: String(localized: "Category", comment: "Chart axis"),
            categoryOrder: snapshot.byCategory.map(\.name)
        )
        let points = snapshot.byCategory.map { item in
            AXDataPoint(
                x: item.name,
                y: NSDecimalNumber(decimal: item.total).doubleValue,
                additionalValues: []
            )
        }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Spending", comment: "Insights chart series"),
            isContinuous: false,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: String(localized: "Spending by Category", comment: "Insights chart title"),
            summary: String(localized: "Category totals in \(snapshot.reportingCode).", comment: "Insights chart summary"),
            xAxis: categoryAxis,
            yAxis: valueAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

#if DEBUG
#Preview("Insights") {
    HowMuchPreview.wrap(
        NavigationStack {
            InsightsView()
        }
    )
    .frame(width: 400, height: 560)
}

#Preview("Insights Accessibility Size") {
    HowMuchPreview.wrap(
        NavigationStack {
            InsightsView()
        }
    )
    .environment(\.dynamicTypeSize, .accessibility3)
    .frame(width: 400, height: 560)
}
#endif
