import CoreData
import Foundation
import SwiftUI

@objc(Category)
public final class Category: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Category> {
        NSFetchRequest<Category>(entityName: "Category")
    }

    @NSManaged public var uuid: UUID?
    @NSManaged public var name: String?
    @NSManaged public var symbolName: String?
    @NSManaged public var colorHex: String?
    @NSManaged public var sortOrder: Int16
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var ledger: Ledger?
    @NSManaged public var expenses: Set<Expense>?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        uuid = UUID()
        createdAt = Date()
        name = ""
        symbolName = "tag"
        colorHex = "5B8DEF"
        isArchived = false
        sortOrder = 0
    }

    var wrappedID: UUID { uuid ?? UUID() }
    var wrappedName: String { name ?? "" }
    var wrappedSymbolName: String { symbolName ?? "tag" }
    var wrappedColorHex: String { colorHex ?? "5B8DEF" }

    var color: Color {
        Color(hex: wrappedColorHex)
    }
}
