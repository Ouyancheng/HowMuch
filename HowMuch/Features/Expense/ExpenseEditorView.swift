import CoreData
import SwiftUI
#if os(iOS)
import PhotosUI
import QuickLook
#endif
#if os(macOS)
import AppKit
#endif

struct ExpenseEditorView: View {
    var expense: Expense?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(AppState.self) private var appState

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Ledger.kind, ascending: true),
            NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)
        ]
    )
    private var ledgers: FetchedResults<Ledger>

    @State private var merchant = ""
    @State private var note = ""
    @State private var occurredAt = Date()
    @State private var spendAmount: Decimal = 0
    @State private var spendCurrency = CurrencyCatalog.localeCurrency
    @State private var chargedAmount: Decimal = 0
    @State private var chargedCurrency = CurrencyCatalog.localeCurrency
    @State private var reportingOverride: Decimal?
    @State private var selectedLedgerID: UUID?
    @State private var selectedCategoryID: NSManagedObjectID?
    @State private var selectedMethodID: NSManagedObjectID?
    @State private var showsDualCurrency = false
    @State private var showingAddPaymentMethod = false
    @State private var errorMessage: String?
    @State private var receipt: ReceiptDraft?
    @State private var didPopulate = false
    @State private var showingDeleteConfirm = false
    @FocusState private var amountFieldFocused: Bool
    #if os(iOS)
    @State private var showingReceiptImporter = false
    @State private var receiptPreviewURL: URL?
    @State private var showingReceiptPhotosPicker = false
    @State private var receiptPhotoItem: PhotosPickerItem?
    #endif

    private var ledger: Ledger? {
        ledgers.first { $0.uuid == selectedLedgerID } ?? LedgerSelection.current(from: ledgers, appState: appState)
    }

    private var selectedCategory: Category? {
        guard let selectedCategoryID else { return nil }
        return try? context.existingObject(with: selectedCategoryID) as? Category
    }

    private var selectedMethod: PaymentMethod? {
        guard let selectedMethodID else { return nil }
        return try? context.existingObject(with: selectedMethodID) as? PaymentMethod
    }

    private var effectiveChargedAmount: Decimal {
        showsDualCurrency ? chargedAmount : spendAmount
    }

    private var effectiveChargedCurrency: String {
        showsDualCurrency ? chargedCurrency : spendCurrency
    }

    private var needsReportingOverride: Bool {
        guard let ledger else { return false }
        return MoneyMath.needsExplicitReportingAmount(
            spendCurrency: spendCurrency,
            chargedCurrency: effectiveChargedCurrency,
            reportingCurrency: ledger.wrappedReportingCurrency
        )
    }

    private var impliedRateText: String? {
        guard showsDualCurrency, let rate = MoneyMath.impliedRate(spend: spendAmount, charged: chargedAmount) else {
            return nil
        }
        return MoneyMath.formatRate(rate, from: spendCurrency, to: chargedCurrency)
    }

    var body: some View {
        Form {
            amountSection
            detailsSection
            receiptSection
            if let ledger {
                categorySection(ledger)
                paymentSection(ledger)
            }
            if expense != nil {
                Section {
                    Button(String(localized: "Delete Expense", comment: "Button"), role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .hmWrappingText()
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minHeight: 0)
        #endif
        .navigationTitle(expense == nil
            ? String(localized: "New Expense", comment: "Screen title")
            : String(localized: "Edit Expense", comment: "Screen title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Button")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $showingReceiptImporter,
            allowedContentTypes: ReceiptDraft.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                applyReceipt { try ReceiptDraft.load(from: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($receiptPreviewURL)
        .photosPicker(isPresented: $showingReceiptPhotosPicker, selection: $receiptPhotoItem, matching: .images)
        .onChange(of: receiptPhotoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ReceiptDraftError.empty
                    }
                    applyReceipt { try ReceiptDraft.make(data: data, fileName: "receipt.jpg", type: .image) }
                } catch {
                    errorMessage = error.localizedDescription
                }
                receiptPhotoItem = nil
            }
        }
        #endif
        .onAppear {
            guard !didPopulate else { return }
            didPopulate = true
            populate()
            if expense == nil {
                amountFieldFocused = true
            }
        }
        .onChange(of: spendAmount) { _, newValue in
            if !showsDualCurrency {
                chargedAmount = newValue
            }
        }
        .onChange(of: spendCurrency) { _, newValue in
            if !showsDualCurrency {
                chargedCurrency = newValue
            }
        }
        .onChange(of: showsDualCurrency) { _, enabled in
            if !enabled {
                chargedAmount = spendAmount
                chargedCurrency = spendCurrency
            } else if let method = selectedMethod {
                chargedCurrency = method.wrappedBillingCurrency
            }
        }
        .onChange(of: selectedLedgerID) { _, _ in
            selectedCategoryID = ledger?.activeCategories.first?.objectID
            selectedMethodID = ledger?.activePaymentMethods.first?.objectID
        }
        .onChange(of: selectedMethodID) { _, _ in
            if let method = selectedMethod {
                if !showsDualCurrency {
                    spendCurrency = method.wrappedBillingCurrency
                    chargedCurrency = method.wrappedBillingCurrency
                } else {
                    chargedCurrency = method.wrappedBillingCurrency
                }
            }
        }
        .confirmationDialog(
            String(localized: "Delete this expense?", comment: "Alert"),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", comment: "Button"), role: .destructive) {
                deleteExpense()
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showingAddPaymentMethod) {
            if let ledger {
                NavigationStack {
                    PaymentMethodEditorView(method: nil, ledger: ledger) { method in
                        selectedMethodID = method.objectID
                    }
                }
                .environmentObject(persistence)
                .environment(\.managedObjectContext, context)
                .hmPaymentEditorFrame()
            }
        }
    }

    @ViewBuilder
    private var receiptSection: some View {
        #if os(iOS)
        ReceiptPickerSection(
            receipt: $receipt,
            errorMessage: $errorMessage,
            showingFileImporter: $showingReceiptImporter,
            previewURL: $receiptPreviewURL,
            onPickPhoto: startReceiptPhotoPicker
        )
        #else
        ReceiptPickerSection(
            receipt: $receipt,
            errorMessage: $errorMessage,
            onPickFile: startReceiptFilePicker
        )
        #endif
    }

    private func applyReceipt(_ make: () throws -> ReceiptDraft) {
        do {
            receipt = try make()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if os(iOS)
    private func startReceiptPhotoPicker() {
        amountFieldFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            showingReceiptPhotosPicker = true
        }
    }
    #endif

    #if os(macOS)
    private func startReceiptFilePicker() {
        amountFieldFocused = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ReceiptDraft.allowedTypes
        panel.message = String(localized: "Choose a photo or PDF receipt.", comment: "Open panel")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                applyReceipt { try ReceiptDraft.load(from: url) }
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
    #endif

    private var detailsSection: some View {
        Section(String(localized: "Details", comment: "Form section")) {
            TextField(String(localized: "Merchant", comment: "Field"), text: $merchant)
            #if os(macOS)
            DatePicker(
                String(localized: "Date", comment: "Field"),
                selection: $occurredAt
            )
            .datePickerStyle(.compact)
            #else
            DatePicker(
                String(localized: "Date", comment: "Field"),
                selection: $occurredAt,
                displayedComponents: .date
            )
            DatePicker(
                String(localized: "Time", comment: "Field"),
                selection: $occurredAt,
                displayedComponents: .hourAndMinute
            )
            #endif
            TextField(String(localized: "Note", comment: "Field"), text: $note, axis: .vertical)
                .lineLimit(2...4)
            if ledgers.count > 1 {
                Picker(String(localized: "Ledger", comment: "Field"), selection: $selectedLedgerID) {
                    ForEach(ledgers, id: \.objectID) { item in
                        Text(item.wrappedName).tag(item.uuid)
                    }
                }
            }
        }
    }

    private func categorySection(_ ledger: Ledger) -> some View {
        Section(String(localized: "Category", comment: "Field")) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ledger.activeCategories, id: \.objectID) { category in
                    CategoryChip(
                        category: category,
                        isSelected: selectedCategoryID == category.objectID
                    ) {
                        selectedCategoryID = category.objectID
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Category", comment: "Field"))
        }
    }

    private func paymentSection(_ ledger: Ledger) -> some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ledger.activePaymentMethods, id: \.objectID) { method in
                    PaymentMethodChip(
                        method: method,
                        isSelected: selectedMethodID == method.objectID
                    ) {
                        selectedMethodID = method.objectID
                    }
                }
                Button {
                    showingAddPaymentMethod = true
                } label: {
                    Label(String(localized: "Add Payment Method", comment: "Toolbar"), systemImage: "plus")
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .hmGlassInteractive(in: Capsule())
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Paid with", comment: "Field"))
        } header: {
            Text("Paid with")
        }
    }

    private var amountSection: some View {
        Section {
            LabeledContent(String(localized: "Spend", comment: "Field")) {
                HStack(spacing: 8) {
                    TextField(String(localized: "Amount", comment: "Field"), value: $spendAmount, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .focused($amountFieldFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    CurrencyPicker(code: $spendCurrency, featuredOnly: true)
                        .fixedSize()
                }
                .frame(maxWidth: 260)
            }

            Toggle(String(localized: "Billed in a different currency", comment: "Toggle"), isOn: $showsDualCurrency)

            if showsDualCurrency {
                LabeledContent(String(localized: "Charged", comment: "Field")) {
                    HStack(spacing: 8) {
                        TextField(String(localized: "Amount", comment: "Field"), value: $chargedAmount, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        CurrencyPicker(code: $chargedCurrency, featuredOnly: true)
                            .fixedSize()
                    }
                    .frame(maxWidth: 260)
                }
                if let impliedRateText {
                    LabeledContent(String(localized: "Implied Rate", comment: "Field"), value: impliedRateText)
                }
            }

            if needsReportingOverride, let ledger {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Amount", comment: "Field"),
                            value: Binding(
                                get: { reportingOverride ?? 0 },
                                set: { reportingOverride = $0 }
                            ),
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        Text(ledger.wrappedReportingCurrency)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                } label: {
                    Text(String(localized: "Ledger total", comment: "Field"))
                }
            }
        } header: {
            Text("Amount")
        } footer: {
            amountFooter
        }
    }

    @ViewBuilder
    private var amountFooter: some View {
        if showsDualCurrency {
            Text("Enter what the card or wallet actually billed.")
                .hmWrappingFooter()
        } else if needsReportingOverride, let ledger {
            Text("This ledger reports in \(ledger.wrappedReportingCurrency). Enter the equivalent total.")
                .hmWrappingFooter()
        }
    }

    private func populate() {
        if let expense {
            merchant = expense.wrappedMerchant
            note = expense.wrappedNote
            occurredAt = expense.wrappedOccurredAt
            spendAmount = expense.wrappedSpendAmount
            spendCurrency = expense.wrappedSpendCurrency
            chargedAmount = expense.wrappedChargedAmount
            chargedCurrency = expense.wrappedChargedCurrency
            showsDualCurrency = expense.isDualCurrency
            selectedLedgerID = expense.ledger?.uuid
            selectedCategoryID = expense.category?.objectID
            selectedMethodID = expense.paymentMethod?.objectID
            if let data = expense.receiptData, !data.isEmpty {
                receipt = ReceiptDraft(
                    data: data,
                    fileName: expense.wrappedReceiptFileName,
                    contentType: expense.receiptContentType ?? ""
                )
            } else {
                receipt = nil
            }
            if let ledger = expense.ledger,
               MoneyMath.needsExplicitReportingAmount(
                spendCurrency: expense.wrappedSpendCurrency,
                chargedCurrency: expense.wrappedChargedCurrency,
                reportingCurrency: ledger.wrappedReportingCurrency
               ) {
                reportingOverride = expense.wrappedReportingAmount
            }
        } else {
            let current = ledger
            selectedLedgerID = current?.uuid ?? appState.selectedLedgerID
            selectedCategoryID = current?.activeCategories.first?.objectID
            let method = current?.activePaymentMethods.first
            selectedMethodID = method?.objectID
            let currency = method?.wrappedBillingCurrency ?? current?.wrappedReportingCurrency ?? CurrencyCatalog.localeCurrency
            spendCurrency = currency
            chargedCurrency = currency
        }
    }

    private func save() {
        errorMessage = nil
        guard let ledger else {
            errorMessage = String(localized: "Select a ledger", comment: "Validation")
            return
        }
        guard spendAmount > 0 else {
            errorMessage = String(localized: "Amount must be greater than zero", comment: "Validation")
            return
        }
        guard let category = selectedCategory else {
            errorMessage = String(localized: "Select a category", comment: "Validation")
            return
        }
        guard let method = selectedMethod else {
            errorMessage = String(localized: "Select a payment method", comment: "Validation")
            return
        }

        let charged = effectiveChargedAmount
        let chargedCode = effectiveChargedCurrency
        guard charged > 0 else {
            errorMessage = String(localized: "Amount must be greater than zero", comment: "Validation")
            return
        }

        if needsReportingOverride, (reportingOverride ?? 0) <= 0 {
            errorMessage = String(localized: "Enter the amount in the ledger reporting currency.", comment: "Validation")
            return
        }

        let record = expense ?? Expense(context: context)
        if expense == nil {
            persistence.assign(record, toSameStoreAs: ledger)
        }
        record.merchant = merchant
        record.note = note
        record.occurredAt = occurredAt
        record.updatedAt = Date()
        record.spendAmount = spendAmount as NSDecimalNumber
        record.spendCurrency = spendCurrency
        record.chargedAmount = charged as NSDecimalNumber
        record.chargedCurrency = chargedCode
        record.reportingAmount = MoneyMath.reportingAmount(
            spend: spendAmount,
            spendCurrency: spendCurrency,
            charged: charged,
            chargedCurrency: chargedCode,
            reportingCurrency: ledger.wrappedReportingCurrency,
            override: needsReportingOverride ? reportingOverride : nil
        ) as NSDecimalNumber
        record.reportingCurrency = ledger.wrappedReportingCurrency
        record.ledger = ledger
        record.category = category
        record.paymentMethod = method
        record.receiptData = receipt?.data
        record.receiptFileName = receipt?.fileName
        record.receiptContentType = receipt?.contentType
        persistence.save()
        appState.selectedLedgerID = ledger.uuid
        dismiss()
    }

    private func deleteExpense() {
        guard let expense else { return }
        persistence.deleteExpense(expense)
        appState.expenseToEdit = nil
        dismiss()
    }
}

private struct PaymentMethodChip: View {
    @ObservedObject var method: PaymentMethod
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(method.wrappedName)
                    Text(method.wrappedBillingCurrency)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: method.paymentKind.symbolName)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(SelectedGlassChip(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SelectedGlassChip: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .hmGlassInteractive(in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.75) : Color.clear,
                    lineWidth: 1.5
                )
            }
    }
}

private struct CategoryChip: View {
    @ObservedObject var category: Category
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(category.wrappedName, systemImage: category.wrappedSymbolName)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? category.color : category.color.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
