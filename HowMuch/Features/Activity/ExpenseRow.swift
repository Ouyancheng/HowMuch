import CoreData
import SwiftUI

struct ExpenseRow: View {
    @ObservedObject var expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((expense.category?.color ?? Color.accentColor).opacity(0.18))
                    .frame(width: 40, height: 40)
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
                if expense.isDualCurrency {
                    Text(CurrencyCatalog.format(expense.wrappedChargedAmount, code: expense.wrappedChargedCurrency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [expense.title]
        parts.append(CurrencyCatalog.format(expense.wrappedSpendAmount, code: expense.wrappedSpendCurrency))
        if expense.isDualCurrency {
            let charged = CurrencyCatalog.format(expense.wrappedChargedAmount, code: expense.wrappedChargedCurrency)
            parts.append(String(localized: "Charged \(charged)", comment: "VoiceOver charged amount"))
        }
        if expense.hasReceipt {
            parts.append(String(localized: "Receipt attached", comment: "VoiceOver"))
        }
        return parts.joined(separator: ", ")
    }
}
