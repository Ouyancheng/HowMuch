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

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .month:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .thirtyDays:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return date >= start
        case .all:
            return true
        }
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
                    .id(ledger.objectID)
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

    var body: some View {
        HMGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(InsightsRange.allCases) { item in
                    Button {
                        range = item
                    } label: {
                        Text(item.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                    }
                    .hmGlassChoiceButton(isSelected: range == item)
                    .accessibilityAddTraits(range == item ? .isSelected : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Range", comment: "Insights"))
    }
}

private struct InsightsSnapshot {
    let reportingCode: String
    let isEmpty: Bool
    let reportingTotal: Decimal
    let byCategory: [(name: String, symbol: String, color: Color, total: Decimal)]
    let bySpend: [(code: String, total: Decimal)]
    let byCharged: [(code: String, total: Decimal)]

    init(expenses: FetchedResults<Expense>, range: InsightsRange, reportingCode: String) {
        self.reportingCode = reportingCode
        let now = Date()
        let calendar = Calendar.current
        let filtered = expenses.filter { range.contains($0.wrappedOccurredAt, now: now, calendar: calendar) }
        isEmpty = filtered.isEmpty

        var total: Decimal = 0
        var categories: [String: (symbol: String, color: Color, total: Decimal)] = [:]
        var spend: [String: Decimal] = [:]
        var charged: [String: Decimal] = [:]
        for expense in filtered {
            let converted = expense.insightsReportingAmount(in: reportingCode)
            total += converted
            let name = expense.category?.wrappedName ?? String(localized: "Other", comment: "Default category")
            let current = categories[name]
            categories[name] = (
                expense.category?.wrappedSymbolName ?? current?.symbol ?? "tag",
                expense.category?.color ?? current?.color ?? .secondary,
                (current?.total ?? 0) + converted
            )
            spend[expense.wrappedSpendCurrency, default: 0] += expense.wrappedSpendAmount
            charged[expense.wrappedChargedCurrency, default: 0] += expense.wrappedChargedAmount
        }
        reportingTotal = total
        byCategory = categories
            .map { (name: $0.key, symbol: $0.value.symbol, color: $0.value.color, total: $0.value.total) }
            .sorted { $0.total > $1.total }
        bySpend = spend.map { (code: $0.key, total: $0.value) }.sorted { $0.code < $1.code }
        byCharged = charged.map { (code: $0.key, total: $0.value) }.sorted { $0.code < $1.code }
    }
}

private struct InsightsContent: View {
    @ObservedObject var ledger: Ledger
    @Binding var range: InsightsRange
    @FetchRequest private var expenses: FetchedResults<Expense>

    init(ledger: Ledger, range: Binding<InsightsRange>) {
        self.ledger = ledger
        _range = range
        _expenses = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Expense.occurredAt, ascending: false)],
            predicate: NSPredicate(format: "ledger == %@", ledger)
        )
    }

    var body: some View {
        let snapshot = InsightsSnapshot(
            expenses: expenses,
            range: range,
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
                    Text("All currencies, in \(snapshot.reportingCode). Default rates when an expense was not entered in this currency.")
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
                    Chart(snapshot.byCategory, id: \.name) { item in
                        BarMark(
                            x: .value(String(localized: "Total", comment: "Chart axis"), item.total),
                            y: .value(String(localized: "Category", comment: "Chart axis"), item.name)
                        )
                        .foregroundStyle(item.color)
                    }
                    .frame(height: max(160, CGFloat(snapshot.byCategory.count) * 36))
                    .accessibilityLabel(String(localized: "By Category", comment: "Insights section"))
                } header: {
                    Text("By Category")
                } footer: {
                    Text("Totals in \(snapshot.reportingCode).")
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
        rows: [(code: String, total: Decimal)],
        reportingCode: String
    ) -> some View {
        Section {
            ForEach(rows, id: \.code) { row in
                LabeledContent(row.code) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CurrencyCatalog.format(row.total, code: row.code))
                            .monospacedDigit()
                        if let converted = DefaultFXRates.convert(row.total, from: row.code, to: reportingCode),
                           !MoneyMath.currenciesMatch(row.code, reportingCode) {
                            Text("≈ \(CurrencyCatalog.format(converted, code: reportingCode))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
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

#if DEBUG
#Preview("Insights") {
    HowMuchPreview.wrap(
        NavigationStack {
            InsightsView()
        }
    )
    .frame(width: 400, height: 560)
}
#endif
