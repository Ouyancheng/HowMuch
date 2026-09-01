import CoreData
import SwiftUI

struct CategoriesEditorView: View {
    @ObservedObject var ledger: Ledger
    @EnvironmentObject private var persistence: PersistenceController
    @FetchRequest private var categories: FetchedResults<Category>
    @State private var showingAdd = false
    @State private var removalError: String?

    private var isWritable: Bool {
        persistence.canWrite(ledger)
    }

    init(ledger: Ledger) {
        _ledger = ObservedObject(wrappedValue: ledger)
        _categories = FetchRequest(
            sortDescriptors: [
                NSSortDescriptor(keyPath: \Category.sortOrder, ascending: true),
                NSSortDescriptor(keyPath: \Category.name, ascending: true)
            ],
            predicate: NSPredicate(format: "ledger == %@ AND isArchived == NO", ledger),
            animation: .default
        )
    }

    var body: some View {
        List {
            ForEach(categories, id: \.objectID) { category in
                categoryRow(category)
                .contextMenu {
                    if isWritable {
                        Button(String(localized: "Remove", comment: "Button"), role: .destructive) {
                            remove(category)
                        }
                    }
                }
                .disabled(!isWritable)
                .deleteDisabled(!isWritable || categories.count <= 1)
                .moveDisabled(!isWritable)
            }
            .onDelete(perform: delete)
            .onMove(perform: move)
        }
        .navigationTitle(String(localized: "Categories", comment: "Screen title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label(String(localized: "Add Category", comment: "Toolbar"), systemImage: "plus")
                }
                .disabled(!isWritable)
            }
            #if os(iOS)
            ToolbarItem(placement: .automatic) {
                EditButton()
                    .disabled(!isWritable)
            }
            #endif
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                CategoryEditorView(category: nil, ledger: ledger)
            }
            .environmentObject(persistence)
            .hmSettingsSheetFrame()
        }
        .alert(
            String(localized: "Can't Remove Category", comment: "Alert"),
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
        .safeAreaInset(edge: .bottom) {
            if !isWritable {
                Text(LedgerAccess.readOnlyExplanation)
                    .hmWrappingFooter()
                    .padding()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let items = Array(categories)
        for index in offsets {
            remove(items[index])
        }
    }

    private func remove(_ category: Category) {
        if let error = persistence.removeCategory(category) {
            removalError = error
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        #if os(macOS)
        HStack {
            NavigationLink {
                CategoryEditorView(category: category)
            } label: {
                categoryLabel(category)
            }
            Spacer(minLength: 8)
            let items = Array(categories)
            let index = items.firstIndex { $0.objectID == category.objectID } ?? 0
            Button {
                move(category, by: -1)
            } label: {
                Label(String(localized: "Move Up", comment: "Category reorder action"), systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(!isWritable || index == 0)
            .accessibilityLabel(String(localized: "Move \(category.wrappedName) up", comment: "Category reorder action"))

            Button {
                move(category, by: 1)
            } label: {
                Label(String(localized: "Move Down", comment: "Category reorder action"), systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(!isWritable || index == items.count - 1)
            .accessibilityLabel(String(localized: "Move \(category.wrappedName) down", comment: "Category reorder action"))
        }
        #else
        NavigationLink {
            CategoryEditorView(category: category)
        } label: {
            categoryLabel(category)
        }
        #endif
    }

    private func categoryLabel(_ category: Category) -> some View {
        Label {
            Text(category.wrappedName)
        } icon: {
            Image(systemName: category.wrappedSymbolName)
                .foregroundStyle(category.color)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(
            String(
                localized: "\(category.wrappedName), \(CategoryIconOption.localizedName(for: category.wrappedSymbolName)), \(CategoryColorOption.localizedName(for: category.wrappedColorHex))",
                comment: "Category row accessibility label"
            )
        )
    }

    private func move(_ category: Category, by offset: Int) {
        var items = Array(categories)
        guard let source = items.firstIndex(where: { $0.objectID == category.objectID }) else { return }
        let destination = source + offset
        guard items.indices.contains(destination) else { return }
        items.swapAt(source, destination)
        do {
            try persistence.reorderCategories(items, in: ledger)
        } catch {
            removalError = error.localizedDescription
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var items = Array(categories)
        items.move(fromOffsets: source, toOffset: destination)
        do {
            try persistence.reorderCategories(items, in: ledger)
        } catch {
            removalError = error.localizedDescription
        }
    }
}

struct CategoryEditorView: View {
    var category: Category?
    var ledger: Ledger?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var persistence: PersistenceController

    @State private var name = ""
    @State private var symbolName = "tag"
    @State private var colorHex = "5B8DEF"
    @State private var errorMessage: String?
    @ScaledMetric(relativeTo: .body) private var colorPreviewSize = 22
    @ScaledMetric(relativeTo: .body) private var colorButtonSize = 28

    private var targetLedger: Ledger? {
        category?.ledger ?? ledger
    }

    private var isWritable: Bool {
        targetLedger.map(persistence.canWrite) ?? false
    }

    var body: some View {
        Form {
            TextField(String(localized: "Name", comment: "Field"), text: $name)
            Picker(String(localized: "Icon", comment: "Field"), selection: $symbolName) {
                ForEach(CategoryIconOption.all) { option in
                    Label(option.localizedName, systemImage: option.symbolName)
                        .tag(option.symbolName)
                }
            }
            HStack {
                Text(String(localized: "Color", comment: "Field"))
                Spacer()
                Circle()
                    .fill(Color(hex: colorHex))
                    .frame(width: colorPreviewSize, height: colorPreviewSize)
                    .accessibilityLabel(CategoryColorOption.localizedName(for: colorHex))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CategoryColorOption.all) { option in
                        Button {
                            colorHex = option.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: option.hex))
                                .frame(width: colorButtonSize, height: colorButtonSize)
                                .overlay {
                                    if colorHex == option.hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(CategoryContrast.foreground(forHex: option.hex))
                                            .accessibilityHidden(true)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.localizedName)
                        .accessibilityValue(
                            colorHex == option.hex
                                ? String(localized: "Selected", comment: "Selection state")
                                : ""
                        )
                        .accessibilityAddTraits(colorHex == option.hex ? .isSelected : [])
                    }
                }
            }
            if category != nil {
                Section {
                    Button(String(localized: "Remove Category", comment: "Button"), role: .destructive) {
                        remove()
                    }
                } footer: {
                    Text(String(localized: "Past expenses keep this category. A category with no expenses is deleted."))
                        .hmWrappingFooter()
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .disabled(!isWritable)
        .navigationTitle(category == nil
            ? String(localized: "Add Category", comment: "Screen title")
            : String(localized: "Category", comment: "Screen title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Button"), action: save)
                    .disabled(!isWritable)
            }
        }
        .onAppear {
            if let category {
                name = category.wrappedName
                symbolName = category.wrappedSymbolName
                colorHex = category.wrappedColorHex
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "Name is required", comment: "Validation")
            return
        }
        guard let targetLedger else { return }
        do {
            _ = try persistence.saveCategory(
                category,
                in: targetLedger,
                name: trimmed,
                symbolName: symbolName,
                colorHex: colorHex
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        guard let category else { return }
        if let error = persistence.removeCategory(category) {
            errorMessage = error
            return
        }
        dismiss()
    }
}
