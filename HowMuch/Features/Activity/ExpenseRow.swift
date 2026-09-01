import CoreData
import SwiftUI

struct ExpenseRow: View {
    @ObservedObject var expense: Expense
    @ScaledMetric(relativeTo: .body) private var categoryIconSize = 40

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((expense.category?.color ?? Color.accentColor).opacity(0.18))
                    .frame(width: categoryIconSize, height: categoryIconSize)
                Image(systemName: expense.category?.wrappedSymbolName ?? "creditcard")
                    .foregroundStyle(expense.category?.color ?? Color.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(expense.wrappedOccurredAt, style: .date)
                    if let method = expense.paymentMethod {
                        Text("·")
                        Text(method.wrappedName)
                    }
                    if expense.hasReceipt {
                        Text("·")
                        Image(systemName: "paperclip")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyCatalog.format(expense.wrappedSpendAmount, code: expense.wrappedSpendCurrency))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .accessibilityLabel(String(
                        localized: "Spent \(CurrencyCatalog.format(expense.wrappedSpendAmount, code: expense.wrappedSpendCurrency))",
                        comment: "VoiceOver spend amount"
                    ))
                if expense.isDualCurrency {
                    Text(CurrencyCatalog.format(expense.wrappedChargedAmount, code: expense.wrappedChargedCurrency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            localized: "Charged \(CurrencyCatalog.format(expense.wrappedChargedAmount, code: expense.wrappedChargedCurrency))",
                            comment: "VoiceOver charged amount"
                        ))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        ExpenseRowAccessibility.text(
            title: expense.title,
            occurredDate: expense.wrappedOccurredAt.formatted(date: .abbreviated, time: .omitted),
            paymentMethod: expense.paymentMethod?.wrappedName,
            spendAmount: CurrencyCatalog.format(
                expense.wrappedSpendAmount,
                code: expense.wrappedSpendCurrency
            ),
            chargedAmount: expense.isDualCurrency
                ? CurrencyCatalog.format(
                    expense.wrappedChargedAmount,
                    code: expense.wrappedChargedCurrency
                )
                : nil,
            category: expense.category?.wrappedName,
            hasReceipt: expense.hasReceipt,
            author: expense.createdByName
        )
    }
}

enum ExpenseRowAccessibility {
    static func text(
        title: String,
        occurredDate: String,
        paymentMethod: String?,
        spendAmount: String,
        chargedAmount: String?,
        category: String?,
        hasReceipt: Bool,
        author: String?
    ) -> String {
        var parts = [
            title,
            String(localized: "On \(occurredDate)", comment: "VoiceOver expense date"),
            spendAmount
        ]
        if let paymentMethod = nonempty(paymentMethod) {
            parts.append(String(localized: "Paid with \(paymentMethod)", comment: "VoiceOver payment method"))
        }
        if let chargedAmount = nonempty(chargedAmount) {
            parts.append(String(localized: "Charged \(chargedAmount)", comment: "VoiceOver charged amount"))
        }
        if let category = nonempty(category) {
            parts.append(String(localized: "Category \(category)", comment: "VoiceOver expense category"))
        }
        if hasReceipt {
            parts.append(String(localized: "Receipt attached", comment: "VoiceOver"))
        }
        if let author = nonempty(author) {
            parts.append(String(localized: "Added by \(author)", comment: "VoiceOver expense attribution"))
        }
        return parts.joined(separator: ", ")
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
