import CoreData
import SwiftUI

struct PaymentMethodsEditorView: View {
    @ObservedObject var ledger: Ledger
    @EnvironmentObject private var persistence: PersistenceController
    @FetchRequest private var methods: FetchedResults<PaymentMethod>
    @State private var showingAdd = false
    @State private var removalError: String?

    init(ledger: Ledger) {
        _ledger = ObservedObject(wrappedValue: ledger)
        _methods = FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \PaymentMethod.name, ascending: true)],
            predicate: NSPredicate(format: "ledger == %@ AND isArchived == NO", ledger),
            animation: .default
        )
    }

    var body: some View {
        List {
            ForEach(methods, id: \.objectID) { method in
                NavigationLink {
                    PaymentMethodEditorView(method: method)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.wrappedName)
                            Text(method.wrappedBillingCurrency)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: method.paymentKind.symbolName)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .contextMenu {
                    if method.canBeRemoved {
                        Button(String(localized: "Remove", comment: "Button"), role: .destructive) {
                            remove(method)
                        }
                    }
                }
                .deleteDisabled(!method.canBeRemoved)
            }
            .onDelete(perform: delete)
        }
        .navigationTitle(String(localized: "Payment Methods", comment: "Screen title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label(String(localized: "Add Payment Method", comment: "Toolbar"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                PaymentMethodEditorView(method: nil, ledger: ledger)
            }
            .environmentObject(persistence)
            .hmPaymentEditorFrame()
        }
        .alert(
            String(localized: "Can't Remove Payment Method", comment: "Alert"),
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button(String(localized: "OK", comment: "Button"), role: .cancel) {}
        } message: {
            if let removalError {
                Text(removalError)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let items = Array(methods)
        for index in offsets {
            remove(items[index])
        }
    }

    private func remove(_ method: PaymentMethod) {
        if let error = persistence.removePaymentMethod(method) {
            removalError = error
        }
    }
}

struct PaymentMethodEditorView: View {
    var method: PaymentMethod?
    var ledger: Ledger?
    var onSaved: ((PaymentMethod) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController

    @State private var name = ""
    @State private var billingCurrency = CurrencyCatalog.localeCurrency
    @State private var kind: PaymentKind = .cash
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                nameCard
                kindCard
                currencyCard
                if method?.canBeRemoved == true {
                    removeButton
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .hmWrappingText()
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(method == nil
            ? String(localized: "Add Payment Method", comment: "Screen title")
            : String(localized: "Payment Method", comment: "Screen title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Button"), action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let method {
                name = method.wrappedName
                billingCurrency = method.wrappedBillingCurrency
                kind = method.paymentKind
            } else if let ledger {
                billingCurrency = ledger.wrappedReportingCurrency
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 32, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .hmGlassInteractive(in: Circle())
            Text(kind.title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Name", comment: "Field"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Name", comment: "Field"), text: $name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hmGlassInteractive(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var kindCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Kind", comment: "Field"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HMGlassGroup(spacing: 8) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(PaymentKind.allCases) { item in
                        PaymentKindChip(kind: item, isSelected: kind == item) {
                            kind = item
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hmGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var currencyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Billing Currency", comment: "Field"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(String(localized: "Billing Currency", comment: "Field"), selection: $billingCurrency) {
                ForEach(CurrencyCatalog.featured, id: \.self) { code in
                    Text(CurrencyCatalog.displayName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("The billing currency is what this card or wallet charges. Dual-currency spends use it as the charged amount.")
                .hmWrappingFooter()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hmGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            remove()
        } label: {
            Text(String(localized: "Remove Payment Method", comment: "Button"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .hmGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHint(String(localized: "Past expenses keep this method. A method with no expenses is deleted.", comment: "Hint"))
    }

    private func remove() {
        guard let method else { return }
        if let error = persistence.removePaymentMethod(method) {
            errorMessage = error
            return
        }
        dismiss()
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "Name is required", comment: "Validation")
            return
        }
        let targetLedger = method?.ledger ?? ledger
        guard let targetLedger else { return }
        let record = method ?? PaymentMethod(context: context)
        if method == nil {
            persistence.assign(record, toSameStoreAs: targetLedger)
            record.ledger = targetLedger
        }
        record.name = trimmed
        record.billingCurrency = billingCurrency
        record.kind = kind.rawValue
        persistence.save()
        onSaved?(record)
        dismiss()
    }
}

struct PaymentKindChip: View {
    let kind: PaymentKind
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                Text(kind.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .modifier(PaymentKindChipChrome(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(kind.title)
    }
}

private struct PaymentKindChipChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .hmGlassInteractive(in: shape)
            .overlay {
                shape.strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 1.5
                )
            }
    }
}

#if DEBUG
#Preview("Add Payment Method") {
    HowMuchPreview.wrap(
        NavigationStack {
            PaymentMethodEditorView(method: nil, ledger: {
                let request = Ledger.fetchRequest()
                return (try? HowMuchPreview.persistence.viewContext.fetch(request))?.first
            }())
        }
    )
    .frame(width: 500, height: 600)
}
#endif
