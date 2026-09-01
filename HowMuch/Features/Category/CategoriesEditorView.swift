import CoreData
import SwiftUI

struct CategoriesEditorView: View {
    @ObservedObject var ledger: Ledger
    @EnvironmentObject private var persistence: PersistenceController
    @FetchRequest private var categories: FetchedResults<Category>
    @State private var showingAdd = false
    @State private var removalError: String?

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
                NavigationLink {
                    CategoryEditorView(category: category)
                } label: {
                    Label {
                        Text(category.wrappedName)
                    } icon: {
                        Image(systemName: category.wrappedSymbolName)
                            .foregroundStyle(category.color)
                    }
                }
                .contextMenu {
                    Button(String(localized: "Remove", comment: "Button"), role: .destructive) {
                        remove(category)
                    }
                }
                .deleteDisabled(categories.count <= 1)
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
            }
            #if os(iOS)
            ToolbarItem(placement: .automatic) {
                EditButton()
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

    private func move(from source: IndexSet, to destination: Int) {
        var items = Array(categories)
        items.move(fromOffsets: source, toOffset: destination)
        for (index, category) in items.enumerated() {
            category.sortOrder = Int16(index)
        }
        persistence.save()
    }
}

struct CategoryEditorView: View {
    var category: Category?
    var ledger: Ledger?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController

    @State private var name = ""
    @State private var symbolName = "tag"
    @State private var colorHex = "5B8DEF"
    @State private var errorMessage: String?

    private let symbols = [
        "fork.knife", "cart", "cup.and.saucer", "bus", "house", "bolt", "bag",
        "cross.case", "book", "airplane", "theatermasks", "repeat", "gift",
        "ellipsis.circle", "heart", "car", "tram", "phone", "gamecontroller", "pawprint"
    ]

    var body: some View {
        Form {
            TextField(String(localized: "Name", comment: "Field"), text: $name)
            Picker(String(localized: "Icon", comment: "Field"), selection: $symbolName) {
                ForEach(symbols, id: \.self) { symbol in
                    Label(symbol, systemImage: symbol).tag(symbol)
                }
            }
            HStack {
                Text(String(localized: "Color", comment: "Field"))
                Spacer()
                Circle().fill(Color(hex: colorHex)).frame(width: 22, height: 22)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["E85D4C", "3D9A5F", "D97706", "2563EB", "7C3AED", "CA8A04", "DB2777", "059669", "4F46E5", "0891B2", "C026D3", "64748B"], id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if colorHex == hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex)
                    }
                }
            }
            if category != nil {
                Section {
                    Button(String(localized: "Remove Category", comment: "Button"), role: .destructive) {
                        remove()
                    }
                } footer: {
                    Text("Past expenses keep this category. A category with no expenses is deleted.")
                        .hmWrappingFooter()
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle(category == nil
            ? String(localized: "Add Category", comment: "Screen title")
            : String(localized: "Category", comment: "Screen title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Button"), action: save)
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
        let targetLedger = category?.ledger ?? ledger
        guard let targetLedger else { return }
        let record = category ?? Category(context: context)
        if category == nil {
            persistence.assign(record, toSameStoreAs: targetLedger)
            record.sortOrder = Int16(targetLedger.activeCategories.count)
            record.ledger = targetLedger
        }
        record.name = trimmed
        record.symbolName = symbolName
        record.colorHex = colorHex
        persistence.save()
        dismiss()
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
