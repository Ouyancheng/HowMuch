import CloudKit
import Combine
import CoreData
import Foundation
import os.log

@MainActor
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController(
        enableCloudKit: !isRunningTests
    )

    static let cloudKitContainerIdentifier = "iCloud.com.howmuch.app"

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-XCTest")
    }

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?

    @Published private(set) var cloudKitEnabled: Bool
    @Published var loadError: String?

    private let logger = Logger(subsystem: "com.howmuch.app", category: "Persistence")
    private let inMemory: Bool

    var viewContext: NSManagedObjectContext { container.viewContext }

    var iCloudSyncDetail: String {
        if cloudKitEnabled {
            String(localized: "Private iCloud sync is on for your Apple ID. Family sharing uses a shared iCloud zone.")
        } else if !CloudKitEntitlement.isPresent {
            String(localized: "This build keeps data on this Mac. Choose a Team in Xcode and enable CloudKit to turn on iCloud sync.")
        } else {
            String(localized: "CloudKit is off. Data stays on this device until iCloud sync is available.")
        }
    }

    init(inMemory: Bool = false, enableCloudKit: Bool = true) {
        self.inMemory = inMemory
        self.cloudKitEnabled = enableCloudKit && !inMemory && !Self.isRunningTests && CloudKitEntitlement.isPresent
        container = NSPersistentCloudKitContainer(name: "HowMuch")
        configure(enableCloudKit: self.cloudKitEnabled)
        loadStores(allowCloudKitFallback: true)
        configureContext()
        if !inMemory {
            bootstrapIfNeeded()
        }
    }

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true, enableCloudKit: false)
        controller.loadSampleData()
        return controller
    }()

    func save() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    func assign(_ object: NSManagedObject, toSameStoreAs related: NSManagedObject) {
        if let store = related.objectID.persistentStore {
            viewContext.assign(object, to: store)
        } else if let privateStore {
            viewContext.assign(object, to: privateStore)
        }
    }

    /// Hides a category from pickers. Unused categories are deleted; categories
    /// still referenced by expenses are archived so history stays intact.
    func removeCategory(_ category: Category) -> String? {
        guard let ledger = category.ledger, ledger.activeCategories.count > 1 else {
            return String(localized: "Keep at least one category.", comment: "Validation")
        }
        removeUnusedOrArchive(category, unused: category.expenses?.isEmpty ?? true) {
            category.isArchived = true
        }
        return nil
    }

    /// Hides a payment method from pickers. Cash cannot be removed. Unused
    /// methods are deleted; methods still referenced by expenses are archived.
    func removePaymentMethod(_ method: PaymentMethod) -> String? {
        guard method.canBeRemoved else {
            return String(localized: "Cash can't be removed.", comment: "Validation")
        }
        guard let ledger = method.ledger, ledger.activePaymentMethods.count > 1 else {
            return String(localized: "Keep at least one payment method.", comment: "Validation")
        }
        removeUnusedOrArchive(method, unused: method.expenses?.isEmpty ?? true) {
            method.isArchived = true
        }
        return nil
    }

    func deleteExpense(_ expense: Expense) {
        viewContext.delete(expense)
        save()
    }

    private func removeUnusedOrArchive(_ object: NSManagedObject, unused: Bool, archive: () -> Void) {
        if unused {
            viewContext.delete(object)
        } else {
            archive()
        }
        save()
    }

    func persistentStore(for object: NSManagedObject) -> NSPersistentStore? {
        object.objectID.persistentStore ?? privateStore
    }

    func isInSharedStore(_ object: NSManagedObject) -> Bool {
        guard let sharedStore else { return false }
        return object.objectID.persistentStore === sharedStore
    }

    #if DEBUG
    func initializeCloudKitSchema() throws {
        try container.initializeCloudKitSchema(options: [])
    }
    #endif

    private func configure(enableCloudKit: Bool) {
        let storesURL = applicationSupportURL()
        try? FileManager.default.createDirectory(at: storesURL, withIntermediateDirectories: true)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.url = URL(fileURLWithPath: "/dev/null")
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            return
        }

        let privateDescription = NSPersistentStoreDescription(url: storesURL.appendingPathComponent("private.sqlite"))
        privateDescription.configuration = "Default"
        privateDescription.shouldAddStoreAsynchronously = false
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        privateDescription.shouldMigrateStoreAutomatically = true
        privateDescription.shouldInferMappingModelAutomatically = true

        if enableCloudKit {
            let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            let sharedDescription = NSPersistentStoreDescription(url: storesURL.appendingPathComponent("shared.sqlite"))
            sharedDescription.configuration = "Default"
            sharedDescription.shouldAddStoreAsynchronously = false
            sharedDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            sharedDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            sharedDescription.shouldMigrateStoreAutomatically = true
            sharedDescription.shouldInferMappingModelAutomatically = true
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions

            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        } else {
            container.persistentStoreDescriptions = [privateDescription]
        }
    }

    private func loadStores(allowCloudKitFallback: Bool) {
        var loadedPrivate: NSPersistentStore?
        var loadedShared: NSPersistentStore?
        var firstError: Error?

        container.loadPersistentStores { description, error in
            if let error {
                firstError = error
                return
            }
            let isShared = description.cloudKitContainerOptions?.databaseScope == .shared
            if isShared {
                loadedShared = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            } else {
                loadedPrivate = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            }
        }

        if let firstError {
            logger.error("Store load failed: \(firstError.localizedDescription, privacy: .public)")
            if allowCloudKitFallback && cloudKitEnabled {
                logger.log("Falling back to local stores without CloudKit")
                cloudKitEnabled = false
                destroyCoordinatorStores()
                configure(enableCloudKit: false)
                loadStores(allowCloudKitFallback: false)
                return
            }
            loadError = firstError.localizedDescription
        }

        privateStore = loadedPrivate ?? container.persistentStoreCoordinator.persistentStores.first
        sharedStore = loadedShared
    }

    private func destroyCoordinatorStores() {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private func configureContext() {
        let context = container.viewContext
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
        context.transactionAuthor = "howmuch"
        context.name = "viewContext"
        do {
            try context.setQueryGenerationFrom(.current)
        } catch {
            logger.error("Query generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applicationSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HowMuch", isDirectory: true)
    }
}

extension NSPersistentStoreCoordinator {
    fileprivate func persistentStore(for url: URL) -> NSPersistentStore? {
        persistentStores.first { $0.url == url }
    }
}
