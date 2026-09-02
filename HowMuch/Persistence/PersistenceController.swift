import CloudKit
import Combine
import CoreData
import Foundation
import os.log

enum PersistentStoreLoadState: Equatable {
    case waitingForAccount
    case loading
    case loaded
    case failed
}

enum CloudSyncActivity: Equatable {
    case unavailable
    case idle
    case importing
    case exporting
    case settingUp
    case failed
}

struct PersistenceDiagnostic: Equatable {
    enum Kind: String {
        case account
        case storeLoad
        case history
        case cloudKit
        case save
    }

    let kind: Kind
    let message: String
}

enum PersistenceMutationError: LocalizedError {
    case saveFailed(String)
    case invalidCategory
    case invalidPaymentMethod

    var errorDescription: String? {
        switch self {
        case .saveFailed(let message):
            String(localized: "Your changes could not be saved: \(message)", comment: "Persistence mutation error")
        case .invalidCategory:
            String(localized: "This category does not belong to the selected ledger.", comment: "Persistence mutation error")
        case .invalidPaymentMethod:
            String(localized: "This payment method does not belong to the selected ledger.", comment: "Persistence mutation error")
        }
    }
}

private struct PersistentHistoryChangeSnapshot: Sendable {
    enum Kind: Sendable {
        case insert
        case update
        case delete
    }

    let objectURI: String
    let kind: Kind
}

private struct PersistentHistoryTransactionSnapshot: Sendable {
    let tokenData: Data
    let timestamp: Date
    let changes: [PersistentHistoryChangeSnapshot]
}

struct CachedLedgerAccess {
    let value: LedgerAccess
    let resolvedAt: Date
}

/// CloudKit still writes sidecars through this class method even when the
/// store URL is custom. Keep it inside the same writable HowMuch directory.
final class HowMuchPersistentContainer: NSPersistentCloudKitContainer {
    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var overrideURL: URL?

    static func setDefaultDirectoryOverride(_ url: URL) {
        overrideLock.lock()
        overrideURL = url
        overrideLock.unlock()
    }

    override class func defaultDirectoryURL() -> URL {
        overrideLock.lock()
        let override = overrideURL
        overrideLock.unlock()
        return override ?? NSPersistentContainer.defaultDirectoryURL()
    }
}

@MainActor
final class PersistenceController: ObservableObject {
    enum TestStoreType {
        case inMemory
        case sqlite
    }

    static let shared: PersistenceController = {
        let controller = PersistenceController(
            inMemory: isRunningTests || isUITesting,
            enableCloudKit: !isRunningTests && !isUITesting
        )
        if isUITesting {
            controller.loadSampleData()
        }
        return controller
    }()

    static let cloudKitContainerIdentifier = "iCloud.com.howmuch.app"

    /// One model instance is shared by every stack in the process. Creating a
    /// model implicitly for each container can register duplicate entity
    /// descriptions when tests create more than one stack.
    static let managedObjectModel: NSManagedObjectModel = {
        guard let modelURL = Bundle.main.url(forResource: "HowMuch", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            preconditionFailure("Unable to load HowMuch.momd from the app bundle")
        }
        return model
    }()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-XCTest")
    }

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    static var isCapturingScreenshots: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-screenshots")
    }

    private(set) var container: NSPersistentContainer
    var persistentCloudKitContainer: NSPersistentCloudKitContainer? {
        container as? NSPersistentCloudKitContainer
    }
    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?

    @Published private(set) var cloudKitEnabled: Bool
    @Published var loadError: String?
    @Published private(set) var saveError: String?
    @Published var shareError: String?
    @Published var hasPendingShareInvitation = false
    @Published private(set) var loadState: PersistentStoreLoadState = .waitingForAccount
    @Published private(set) var syncActivity: CloudSyncActivity = .unavailable
    @Published var diagnostic: PersistenceDiagnostic?
    @Published private(set) var currentAccountFingerprint: String?
    @Published private(set) var stackGeneration = 0
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastImportDate: Date?
    @Published private(set) var lastExportDate: Date?
    @Published private(set) var lastCloudEventDescription: String?
    @Published private(set) var destructiveSharingReady = false
    var pendingStopSharingRetries: [NSManagedObjectID: StopSharingRetry] = [:]
    var systemStopSharingInProgress: Set<NSManagedObjectID> = []
    var pendingShareMetadata: CKShare.Metadata?
    var ledgerAccessCache: [NSManagedObjectID: CachedLedgerAccess] = [:]
    var expenseTransferJournalStore = ExpenseTransferJournalStore()
    #if DEBUG
    var ledgerAccessResolverForTesting: ((Ledger) -> LedgerAccess)?
    var expenseTransferFailureInjector: ((ExpenseTransferFailurePoint) throws -> Void)?
    #endif

    private let logger = Logger(subsystem: "com.howmuch.app", category: "Persistence")
    private let inMemory: Bool
    private let testStoreType: TestStoreType?
    private let includeSharedTestStore: Bool
    private let localOnlyMode: Bool
    private let supportsCloudKit: Bool
    private var offlineLocalStoreActive = false
    private let applicationSupportDirectoryOverride: URL?
    private var configuredSharedStoreURLs: Set<URL> = []
    private var remoteChangeObserver: NSObjectProtocol?
    private var cloudEventObserver: NSObjectProtocol?
    private var historyProcessingTask: Task<Void, Never>?
    private var historyProcessingRequested = false
    private var historyProcessingNonce = UUID()

    var viewContext: NSManagedObjectContext { container.viewContext }
    var isDataAvailable: Bool { loadState == .loaded }
    var isLocalOnly: Bool { localOnlyMode || offlineLocalStoreActive }

    var iCloudSyncDetail: String {
        if cloudKitEnabled {
            String(localized: "Private iCloud sync is on for your Apple Account. Family sharing uses a shared iCloud zone.")
        } else if localOnlyMode {
            PlatformCopy.localOnlyBuildDetail
        } else if offlineLocalStoreActive {
            PlatformCopy.signedOutLocalDetail
        } else {
            String(localized: "CloudKit is off. Data stays on this device until iCloud sync is available.")
        }
    }

    init(
        inMemory: Bool = false,
        enableCloudKit: Bool = true,
        testStoreType: TestStoreType? = nil,
        includeSharedTestStore: Bool = false,
        cloudKitEntitlementPresent: Bool? = nil,
        applicationSupportDirectory: URL? = nil
    ) {
        let entitlementPresent = cloudKitEntitlementPresent ?? CloudKitEntitlement.isPresent
        let hasInjectedDiskLocation = applicationSupportDirectory != nil
        let useInMemoryStore = testStoreType == .inMemory
            || (
                testStoreType == nil
                    && (
                        inMemory
                            || (!hasInjectedDiskLocation && (Self.isRunningTests || Self.isUITesting))
                    )
            )
        self.inMemory = useInMemoryStore
        self.testStoreType = testStoreType
        self.includeSharedTestStore = includeSharedTestStore
        self.localOnlyMode = testStoreType == nil && !useInMemoryStore && !entitlementPresent
        self.supportsCloudKit = enableCloudKit
            && testStoreType == nil
            && !useInMemoryStore
            && entitlementPresent
        self.applicationSupportDirectoryOverride = applicationSupportDirectory
        // CloudKit is turned on only after a verified account mounts scoped stores.
        self.cloudKitEnabled = false
        let supportURL = Self.resolvedApplicationSupportURL(override: applicationSupportDirectory)
        HowMuchPersistentContainer.setDefaultDirectoryOverride(supportURL)
        // Local and unsigned sessions must not use NSPersistentCloudKitContainer.
        // That class still writes CloudKit sidecars on save and fails with
        // NSCocoaErrorDomain 513 when iCloud is unavailable.
        container = Self.makeContainer(cloudKit: false)
        configureContext()

        if testStoreType != nil || useInMemoryStore {
            configure(enableCloudKit: false, accountFingerprint: nil)
            if loadStores() {
                loadState = .loaded
                syncActivity = .idle
            }
        } else {
            // Entitled builds stay usable without iCloud: local private data
            // first, then a remount into the verified account when signed in.
            mountOfflineLocalStore()
        }
    }

    static func makeTestStack(
        storeType: TestStoreType = .inMemory,
        includeSharedStore: Bool = false
    ) -> PersistenceController {
        PersistenceController(
            enableCloudKit: false,
            testStoreType: storeType,
            includeSharedTestStore: includeSharedStore
        )
    }

    static func makeLocalTestStack(applicationSupportDirectory: URL) -> PersistenceController {
        PersistenceController(
            enableCloudKit: true,
            cloudKitEntitlementPresent: false,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func makeCloudKitCapableTestStack(applicationSupportDirectory: URL) -> PersistenceController {
        PersistenceController(
            enableCloudKit: true,
            cloudKitEntitlementPresent: true,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true, enableCloudKit: false)
        controller.loadSampleData()
        return controller
    }()

    func applyAccountIdentity(_ identity: CloudAccountIdentity) async {
        guard testStoreType == nil, !inMemory else { return }
        guard !localOnlyMode else { return }

        switch identity {
        case .resolving:
            // Keep whatever store is already usable while CloudKit finishes
            // checking. A cold start already mounted the offline local store.
            if loadState != .loaded {
                mountOfflineLocalStore()
            }
        case .signedOut, .unavailable:
            mountOfflineLocalStore()
        case .available(let fingerprint):
            guard supportsCloudKit else {
                mountOfflineLocalStore()
                return
            }
            if currentAccountFingerprint == fingerprint, loadState == .loaded, cloudKitEnabled {
                return
            }
            await mountStores(for: fingerprint)
        }
    }

    /// Explicitly retries the currently verified account. It never changes
    /// store scope and never retries against an unresolved identity.
    func retryCloudKitLoad() async {
        guard let currentAccountFingerprint else {
            let message = String(
                localized: "Verify your iCloud account before retrying.",
                comment: "Persistence error"
            )
            loadError = message
            diagnostic = PersistenceDiagnostic(kind: .account, message: message)
            return
        }
        await mountStores(for: currentAccountFingerprint)
    }

    func retryStoreLoad() async {
        if localOnlyMode || offlineLocalStoreActive {
            offlineLocalStoreActive = false
            mountOfflineLocalStore()
            await Task.yield()
        } else {
            await retryCloudKitLoad()
        }
    }

    private func mountOfflineLocalStore() {
        if offlineLocalStoreActive, loadState == .loaded {
            cloudKitEnabled = false
            currentAccountFingerprint = nil
            return
        }
        cloudKitEnabled = false
        currentAccountFingerprint = nil
        offlineLocalStoreActive = true
        mountLocalStore()
    }

    private func mountLocalStore() {
        guard invalidateMountedStores() else {
            failCoordinatorUnmount()
            return
        }
        replaceContainer(cloudKit: false)
        loadState = .loading
        loadError = nil
        diagnostic = nil
        syncActivity = .unavailable

        do {
            try prepareWritableStoreDirectories()
            let locations = try CloudStoreScope.prepareLocalStoreIfNeeded(
                baseDirectory: applicationSupportURL()
            )
            configureLocalStore(at: locations.privateStore)
        } catch {
            failStoreLoad(
                error,
                prefix: String(localized: "Local data could not be safely prepared.")
            )
            return
        }

        guard loadStores() else { return }
        repairLoadedStorePermissions()
        loadState = .loaded
        syncActivity = .unavailable
        stackGeneration += 1
        bootstrapIfNeeded()
        recoverPendingExpenseTransfers()
    }

    private func mountStores(for fingerprint: String) async {
        guard invalidateMountedStores() else {
            failCoordinatorUnmount()
            return
        }
        replaceContainer(cloudKit: true)
        offlineLocalStoreActive = false
        cloudKitEnabled = supportsCloudKit
        currentAccountFingerprint = fingerprint
        loadState = .loading
        loadError = nil
        diagnostic = nil
        syncActivity = .settingUp
        destructiveSharingReady = false

        do {
            try prepareWritableStoreDirectories()
            try CloudStoreScope.adoptUnscopedStoresIfNeeded(
                baseDirectory: applicationSupportURL(),
                fingerprint: fingerprint
            )
        } catch {
            failStoreLoad(error, prefix: String(localized: "Existing data could not be safely adopted."))
            return
        }

        configure(enableCloudKit: true, accountFingerprint: fingerprint)
        guard loadStores() else { return }
        repairLoadedStorePermissions()

        configureQueryGeneration()
        installStoreObservers()
        loadState = .loaded
        syncActivity = .idle
        stackGeneration += 1
        bootstrapIfNeeded()
        recoverPendingExpenseTransfers()
        processPersistentHistory()
        retryPendingShareInvitation()
        await Task.yield()
    }

    func save() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try saveMutationContext()
        } catch {
            context.rollback()
            let message = error.localizedDescription
            saveError = message
            diagnostic = PersistenceDiagnostic(kind: .save, message: message)
        }
    }

    func updateLedger(_ ledger: Ledger, name: String, reportingCurrency: String) throws {
        try assertWritable(ledger)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        ledger.name = trimmed.isEmpty ? ledger.wrappedName : trimmed
        ledger.reportingCurrency = reportingCurrency
        ledger.updatedAt = Date()
        do {
            try saveMutationContext()
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    @discardableResult
    func saveCategory(
        _ category: Category?,
        in ledger: Ledger,
        name: String,
        symbolName: String,
        colorHex: String
    ) throws -> Category {
        try assertWritable(ledger)
        if let category, category.ledger?.objectID != ledger.objectID {
            throw PersistenceMutationError.invalidCategory
        }

        let record = category ?? Category(context: viewContext)
        if category == nil {
            assign(record, toSameStoreAs: ledger)
            record.sortOrder = Int16(ledger.activeCategories.count)
            record.ledger = ledger
        }
        record.name = name
        record.symbolName = symbolName
        record.colorHex = colorHex
        do {
            try saveMutationContext()
            return record
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    @discardableResult
    func savePaymentMethod(
        _ method: PaymentMethod?,
        in ledger: Ledger,
        name: String,
        billingCurrency: String,
        kind: PaymentKind
    ) throws -> PaymentMethod {
        try assertWritable(ledger)
        if let method, method.ledger?.objectID != ledger.objectID {
            throw PersistenceMutationError.invalidPaymentMethod
        }

        let record = method ?? PaymentMethod(context: viewContext)
        if method == nil {
            assign(record, toSameStoreAs: ledger)
            record.ledger = ledger
        }
        record.name = name
        record.billingCurrency = billingCurrency
        record.kind = kind.rawValue
        do {
            try saveMutationContext()
            return record
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    func reorderCategories(_ categories: [Category], in ledger: Ledger) throws {
        try assertWritable(ledger)
        guard categories.allSatisfy({ $0.ledger?.objectID == ledger.objectID }) else {
            throw PersistenceMutationError.invalidCategory
        }
        for (index, category) in categories.enumerated() {
            category.sortOrder = Int16(index)
        }
        do {
            try saveMutationContext()
        } catch {
            viewContext.rollback()
            throw error
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
        guard let ledger = category.ledger else {
            return LedgerAccessError.ledgerUnavailable.localizedDescription
        }
        do {
            try assertWritable(ledger)
        } catch {
            return error.localizedDescription
        }
        guard ledger.activeCategories.count > 1 else {
            return String(localized: "Keep at least one category.", comment: "Validation")
        }
        do {
            try removeUnusedOrArchive(category, unused: category.expenses?.isEmpty ?? true) {
                category.isArchived = true
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Hides a payment method from pickers. Cash cannot be removed. Unused
    /// methods are deleted; methods still referenced by expenses are archived.
    func removePaymentMethod(_ method: PaymentMethod) -> String? {
        guard let ledger = method.ledger else {
            return LedgerAccessError.ledgerUnavailable.localizedDescription
        }
        do {
            try assertWritable(ledger)
        } catch {
            return error.localizedDescription
        }
        guard method.canBeRemoved else {
            return String(localized: "Cash can't be removed.", comment: "Validation")
        }
        guard ledger.activePaymentMethods.count > 1 else {
            return String(localized: "Keep at least one payment method.", comment: "Validation")
        }
        do {
            try removeUnusedOrArchive(method, unused: method.expenses?.isEmpty ?? true) {
                method.isArchived = true
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func deleteExpense(_ expense: Expense) throws {
        guard let ledger = expense.ledger else {
            throw LedgerAccessError.ledgerUnavailable
        }
        try assertWritable(ledger)
        viewContext.delete(expense)
        do {
            try saveMutationContext()
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    private func removeUnusedOrArchive(
        _ object: NSManagedObject,
        unused: Bool,
        archive: () -> Void
    ) throws {
        if unused {
            viewContext.delete(object)
        } else {
            archive()
        }
        do {
            try saveMutationContext()
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    func saveMutationContext() throws {
        let context = viewContext
        guard context.hasChanges else { return }
        try assertWritableChanges(in: context)
        do {
            try context.save()
            saveError = nil
        } catch {
            if Self.isFilePermissionError(error) {
                logger.error("Save hit a permission error; repairing store directories and retrying.")
                try? prepareWritableStoreDirectories()
                repairLoadedStorePermissions()
                do {
                    try context.save()
                    saveError = nil
                    return
                } catch {
                    throw persistSaveError(error)
                }
            }
            throw persistSaveError(error)
        }
    }

    private func persistSaveError(_ error: Error) -> PersistenceMutationError {
        logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        let message = Self.safeErrorMessage(error, storeURL: privateStore?.url)
        saveError = message
        diagnostic = PersistenceDiagnostic(kind: .save, message: message)
        return PersistenceMutationError.saveFailed(message)
    }

    private func assertWritableChanges(in context: NSManagedObjectContext) throws {
        let changedObjects = context.insertedObjects
            .union(context.updatedObjects)
            .union(context.deletedObjects)

        var checkedLedgerIDs: Set<NSManagedObjectID> = []
        for object in changedObjects {
            let ledger: Ledger?
            switch object {
            case let ledgerObject as Ledger:
                ledger = ledgerObject
            case let expense as Expense:
                ledger = expense.ledger
            case let category as Category:
                ledger = category.ledger
            case let method as PaymentMethod:
                ledger = method.ledger
            default:
                ledger = nil
            }

            guard let ledger else {
                if object is Ledger || object is Expense || object is Category || object is PaymentMethod {
                    throw LedgerAccessError.ledgerUnavailable
                }
                continue
            }
            guard checkedLedgerIDs.insert(ledger.objectID).inserted else { continue }

            if ledger.isInserted,
               !isInSharedStore(ledger),
               ledger.isPersonal || ledger.isHousehold {
                continue
            }
            if ledger.isDeleted {
                switch access(
                    for: ledger,
                    forceRefresh: cloudKitEnabled && ledger.isHousehold
                ) {
                case .personalOwner, .unsharedOwner, .sharedOwner, .readWriteParticipant:
                    continue
                case .readOnlyParticipant:
                    throw LedgerAccessError.readOnly
                case .unknown:
                    throw LedgerAccessError.accessUnavailable
                }
            } else {
                try assertWritable(ledger)
            }
        }
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
        guard let persistentCloudKitContainer else {
            throw CocoaError(.coderValueNotFound)
        }
        try persistentCloudKitContainer.initializeCloudKitSchema(options: [])
    }
    #endif

    private static func makeContainer(cloudKit: Bool) -> NSPersistentContainer {
        if cloudKit {
            return HowMuchPersistentContainer(
                name: "HowMuch",
                managedObjectModel: managedObjectModel
            )
        }
        return NSPersistentContainer(
            name: "HowMuch",
            managedObjectModel: managedObjectModel
        )
    }

    private func replaceContainer(cloudKit: Bool) {
        let alreadyCloudKit = container is NSPersistentCloudKitContainer
        if alreadyCloudKit == cloudKit {
            return
        }
        HowMuchPersistentContainer.setDefaultDirectoryOverride(
            Self.resolvedApplicationSupportURL(override: applicationSupportDirectoryOverride)
        )
        container = Self.makeContainer(cloudKit: cloudKit)
        configureContext()
    }

    private func configure(enableCloudKit: Bool, accountFingerprint: String?) {
        configuredSharedStoreURLs.removeAll()

        if let testStoreType {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("HowMuchTests-\(UUID().uuidString)", isDirectory: true)
            if testStoreType == .sqlite {
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }

            let privateURL = root.appendingPathComponent("private.sqlite")
            let privateDescription = testStoreDescription(type: testStoreType, url: privateURL)
            if includeSharedTestStore {
                let sharedURL = root.appendingPathComponent("shared.sqlite")
                let sharedDescription = testStoreDescription(type: testStoreType, url: sharedURL)
                configuredSharedStoreURLs.insert(sharedURL)
                container.persistentStoreDescriptions = [privateDescription, sharedDescription]
            } else {
                container.persistentStoreDescriptions = [privateDescription]
            }
            return
        }

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.url = FileManager.default.temporaryDirectory
                .appendingPathComponent("HowMuch-\(UUID().uuidString).sqlite")
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            return
        }

        guard let accountFingerprint else {
            container.persistentStoreDescriptions = []
            return
        }
        let storesURL = CloudStoreScope.locations(
            baseDirectory: applicationSupportURL(),
            fingerprint: accountFingerprint
        ).directory
        try? FileManager.default.createDirectory(at: storesURL, withIntermediateDirectories: true)
        let privateURL = storesURL.appendingPathComponent("private.sqlite")
        try? CloudStoreScope.ensureWritableStoreLocation(privateURL)

        let privateDescription = NSPersistentStoreDescription(url: privateURL)
        configureDiskStoreDescription(privateDescription, trackHistory: true)

        if enableCloudKit {
            let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            let sharedURL = storesURL.appendingPathComponent("shared.sqlite")
            try? CloudStoreScope.ensureWritableStoreLocation(sharedURL)
            let sharedDescription = NSPersistentStoreDescription(url: sharedURL)
            configureDiskStoreDescription(sharedDescription, trackHistory: true)
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions

            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        } else {
            container.persistentStoreDescriptions = [privateDescription]
        }
    }

    private func prepareWritableStoreDirectories() throws {
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try CloudStoreScope.ensureWritableDirectory(HowMuchPersistentContainer.defaultDirectoryURL())
        try CloudStoreScope.ensureWritableDirectory(applicationSupportURL())
    }

    private func repairLoadedStorePermissions() {
        if let url = privateStore?.url {
            try? CloudStoreScope.ensureWritableStoreLocation(url, allowRewrite: false)
        }
        if let url = sharedStore?.url {
            try? CloudStoreScope.ensureWritableStoreLocation(url, allowRewrite: false)
        }
    }

    private func configureLocalStore(at url: URL) {
        configuredSharedStoreURLs.removeAll()
        let description = NSPersistentStoreDescription(url: url)
        // History tracking cannot be turned off after a store has used it.
        // The local sqlite is a copy of the CloudKit private store, so opening
        // it without this key forces Core Data into read-only mode and every
        // save fails with NSCocoaErrorDomain 513.
        configureDiskStoreDescription(description, trackHistory: true)
        description.cloudKitContainerOptions = nil
        container.persistentStoreDescriptions = [description]
    }

    private func configureDiskStoreDescription(
        _ description: NSPersistentStoreDescription,
        trackHistory: Bool
    ) {
        description.configuration = "Default"
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        if trackHistory {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(
                true as NSNumber,
                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
            )
        }
        #if os(iOS)
        #if targetEnvironment(simulator)
        description.setOption(
            FileProtectionType.none as NSObject,
            forKey: NSPersistentStoreFileProtectionKey
        )
        #else
        description.setOption(
            FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
            forKey: NSPersistentStoreFileProtectionKey
        )
        #endif
        #endif
    }

    private func testStoreDescription(type: TestStoreType, url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.type = type == .inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        description.configuration = "Default"
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        if type == .sqlite {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(
                true as NSNumber,
                forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
            )
        }
        return description
    }

    @discardableResult
    private func loadStores() -> Bool {
        var loadedPrivate: NSPersistentStore?
        var loadedShared: NSPersistentStore?
        var firstError: Error?

        container.loadPersistentStores { description, error in
            if let error {
                firstError = error
                return
            }
            let isShared = description.cloudKitContainerOptions?.databaseScope == .shared
                || description.url.map(self.configuredSharedStoreURLs.contains) == true
            if isShared {
                loadedShared = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            } else {
                loadedPrivate = self.container.persistentStoreCoordinator.persistentStore(for: description.url!)
            }
        }

        if let firstError {
            logger.error("Store load failed: \(firstError.localizedDescription, privacy: .public)")
            failStoreLoad(firstError)
            return false
        }

        privateStore = loadedPrivate ?? container.persistentStoreCoordinator.persistentStores.first
        sharedStore = loadedShared
        guard privateStore != nil else {
            failStoreLoad(
                CocoaError(.persistentStoreOperation),
                prefix: String(localized: "The private data store did not load.")
            )
            return false
        }
        loadError = nil
        return true
    }

    @discardableResult
    private func invalidateMountedStores() -> Bool {
        removeStoreObservers()
        historyProcessingTask?.cancel()
        historyProcessingTask = nil
        historyProcessingRequested = false
        historyProcessingNonce = UUID()
        viewContext.reset()
        pendingStopSharingRetries.removeAll()
        systemStopSharingInProgress.removeAll()
        ledgerAccessCache.removeAll()
        destructiveSharingReady = false
        guard destroyCoordinatorStores() else {
            return false
        }
        privateStore = nil
        sharedStore = nil
        if loadState == .loaded || loadState == .loading || loadState == .failed {
            stackGeneration += 1
        }
        return true
    }

    @discardableResult
    private func destroyCoordinatorStores() -> Bool {
        let coordinator = container.persistentStoreCoordinator
        var succeeded = true
        for store in Array(coordinator.persistentStores) {
            do {
                try coordinator.remove(store)
            } catch {
                succeeded = false
                logger.error("Unable to unmount store: \(error.localizedDescription, privacy: .public)")
            }
        }
        return succeeded && coordinator.persistentStores.isEmpty
    }

    private func failCoordinatorUnmount() {
        let message = String(
            localized: "The previous account's data stores could not be closed. No other account was opened. Quit and relaunch the app before trying again.",
            comment: "Persistent store unmount error"
        )
        loadState = .failed
        syncActivity = .failed
        loadError = message
        diagnostic = PersistenceDiagnostic(kind: .storeLoad, message: message)
    }

    private func configureContext() {
        let context = container.viewContext
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
        context.transactionAuthor = "howmuch"
        context.name = "viewContext"
    }

    private func configureQueryGeneration() {
        guard testStoreType == nil else { return }
        do {
            try viewContext.setQueryGenerationFrom(.current)
        } catch {
            logger.error("Query generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func failStoreLoad(_ error: Error, prefix: String? = nil) {
        invalidateMountedStores()
        let detail = Self.safeErrorMessage(error)
        let message = prefix.map { "\($0) \(detail)" } ?? detail
        loadState = .failed
        syncActivity = .failed
        loadError = message
        diagnostic = PersistenceDiagnostic(kind: .storeLoad, message: message)
    }

    nonisolated private static func isFilePermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteNoPermission.rawValue {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    nonisolated private static func safeErrorMessage(_ error: Error, storeURL: URL? = nil) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"]
        if let path = nsError.userInfo[NSFilePathErrorKey] as? String, !path.isEmpty {
            parts.append(path)
        } else if let url = nsError.userInfo[NSURLErrorKey] as? URL {
            parts.append(url.path)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
            if let path = underlying.userInfo[NSFilePathErrorKey] as? String, !path.isEmpty {
                parts.append(path)
            }
        }
        if let storeURL {
            parts.append(storeURL.path)
        }
        return parts.joined(separator: " — ")
    }

    private func installStoreObservers() {
        removeStoreObservers()
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateLedgerAccess()
                self?.processPersistentHistory()
            }
        }
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else {
                return
            }
            let eventKind: Int
            switch event.type {
            case .setup:
                eventKind = 0
            case .import:
                eventKind = 1
            case .export:
                eventKind = 2
            @unknown default:
                eventKind = 3
            }
            let endDate = event.endDate
            let succeeded = event.succeeded
            let errorMessage = event.error.map { Self.safeErrorMessage($0) }
            Task { @MainActor in
                self?.recordCloudEvent(
                    kind: eventKind,
                    endDate: endDate,
                    succeeded: succeeded,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func removeStoreObservers() {
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
            self.remoteChangeObserver = nil
        }
        if let cloudEventObserver {
            NotificationCenter.default.removeObserver(cloudEventObserver)
            self.cloudEventObserver = nil
        }
    }

    private func processPersistentHistory() {
        guard loadState == .loaded, let fingerprint = currentAccountFingerprint else { return }
        historyProcessingRequested = true
        guard historyProcessingTask == nil else { return }
        let nonce = UUID()
        historyProcessingNonce = nonce
        historyProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.historyProcessingRequested, !Task.isCancelled {
                self.historyProcessingRequested = false
                await self.processPersistentHistoryPass(fingerprint: fingerprint)
            }
            if self.historyProcessingNonce == nonce {
                self.historyProcessingTask = nil
            }
        }
    }

    private func processPersistentHistoryPass(fingerprint: String) async {
        guard loadState == .loaded, currentAccountFingerprint == fingerprint else { return }
        let stores = [
            ("private", privateStore),
            ("shared", sharedStore)
        ].compactMap { role, store -> (role: String, identifier: String)? in
            guard let store else { return nil }
            return (role, store.identifier)
        }

        for store in stores {
            guard !Task.isCancelled,
                  loadState == .loaded,
                  currentAccountFingerprint == fingerprint else { return }
            let tokenKey = Self.historyTokenKey(fingerprint: fingerprint, role: store.role)
            let result = await fetchPersistentHistory(
                after: UserDefaults.standard.data(forKey: tokenKey),
                storeIdentifier: store.identifier
            )
            guard !Task.isCancelled else { return }
            if let errorMessage = result.errorMessage {
                diagnostic = PersistenceDiagnostic(kind: .history, message: errorMessage)
                continue
            }

            configureQueryGeneration()
            for transaction in result.transactions {
                guard !Task.isCancelled else { return }
                mergePersistentHistoryChanges(transaction.changes)
                // Advance only after this transaction's object-ID
                // notification has merged into the view context.
                UserDefaults.standard.set(transaction.tokenData, forKey: tokenKey)
                lastSyncDate = max(lastSyncDate ?? .distantPast, transaction.timestamp)
            }
        }
    }

    private func fetchPersistentHistory(
        after tokenData: Data?,
        storeIdentifier: String
    ) async -> (
        transactions: [PersistentHistoryTransactionSnapshot],
        errorMessage: String?
    ) {
        let context = container.newBackgroundContext()
        context.name = "historyProcessor"
        context.transactionAuthor = "howmuch.history"

        return await context.perform {
            do {
                let token: NSPersistentHistoryToken?
                if let tokenData {
                    token = try NSKeyedUnarchiver.unarchivedObject(
                        ofClass: NSPersistentHistoryToken.self,
                        from: tokenData
                    )
                } else {
                    token = nil
                }

                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                if let transactionFetch = NSPersistentHistoryTransaction.fetchRequest {
                    transactionFetch.predicate = NSPredicate(
                        format: "storeID == %@ AND (author == nil OR author != %@)",
                        storeIdentifier,
                        "howmuch"
                    )
                    request.fetchRequest = transactionFetch
                }
                let result = try context.execute(request) as? NSPersistentHistoryResult
                let transactions = result?.result as? [NSPersistentHistoryTransaction] ?? []
                let snapshots = try transactions.map { transaction in
                    let notification = transaction.objectIDNotification()
                    let keys: [(String, PersistentHistoryChangeSnapshot.Kind)] = [
                        (NSInsertedObjectsKey, .insert),
                        (NSUpdatedObjectsKey, .update),
                        (NSDeletedObjectsKey, .delete)
                    ]
                    let changes = keys.flatMap { key, kind in
                        let objectIDs: [NSManagedObjectID]
                        if let values = notification.userInfo?[key] as? Set<NSManagedObjectID> {
                            objectIDs = Array(values)
                        } else if let values = notification.userInfo?[key] as? NSSet {
                            objectIDs = values.compactMap { $0 as? NSManagedObjectID }
                        } else {
                            objectIDs = []
                        }
                        return objectIDs.map { objectID in
                            PersistentHistoryChangeSnapshot(
                                objectURI: objectID.uriRepresentation().absoluteString,
                                kind: kind
                            )
                        }
                    }
                    let encoded = try NSKeyedArchiver.archivedData(
                        withRootObject: transaction.token,
                        requiringSecureCoding: true
                    )
                    return PersistentHistoryTransactionSnapshot(
                        tokenData: encoded,
                        timestamp: transaction.timestamp,
                        changes: changes
                    )
                }
                return (snapshots, nil)
            } catch {
                return ([], Self.safeErrorMessage(error))
            }
        }
    }

    private func mergePersistentHistoryChanges(
        _ changes: [PersistentHistoryChangeSnapshot]
    ) {
        guard !changes.isEmpty else { return }
        invalidateLedgerAccess()
        let coordinator = container.persistentStoreCoordinator
        var inserted: Set<NSManagedObjectID> = []
        var updated: Set<NSManagedObjectID> = []
        var deleted: Set<NSManagedObjectID> = []

        for change in changes {
            guard let url = URL(string: change.objectURI),
                  let objectID = coordinator.managedObjectID(forURIRepresentation: url) else {
                continue
            }
            switch change.kind {
            case .insert:
                inserted.insert(objectID)
            case .update:
                updated.insert(objectID)
            case .delete:
                deleted.insert(objectID)
            }
        }

        var userInfo: [AnyHashable: Any] = [:]
        if !inserted.isEmpty { userInfo[NSInsertedObjectsKey] = inserted }
        if !updated.isEmpty { userInfo[NSUpdatedObjectsKey] = updated }
        if !deleted.isEmpty { userInfo[NSDeletedObjectsKey] = deleted }
        guard !userInfo.isEmpty else { return }
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: userInfo,
            into: [viewContext]
        )
    }

    static func historyTokenKey(fingerprint: String, role: String) -> String {
        "persistence.historyToken.v1.\(fingerprint).\(role)"
    }

    private func recordCloudEvent(
        kind: Int,
        endDate: Date?,
        succeeded: Bool,
        errorMessage: String?
    ) {
        let eventName: String
        switch kind {
        case 0:
            eventName = String(localized: "Setup", comment: "CloudKit event")
            syncActivity = endDate == nil ? .settingUp : .idle
            if endDate == nil {
                destructiveSharingReady = false
            }
        case 1:
            eventName = String(localized: "Import", comment: "CloudKit event")
            syncActivity = endDate == nil ? .importing : .idle
            invalidateLedgerAccess()
            if endDate == nil {
                destructiveSharingReady = false
            }
        case 2:
            eventName = String(localized: "Export", comment: "CloudKit event")
            syncActivity = endDate == nil ? .exporting : .idle
        default:
            eventName = String(localized: "Sync", comment: "CloudKit event")
        }

        guard let endDate else {
            lastCloudEventDescription = String(
                localized: "\(eventName) in progress",
                comment: "CloudKit event status"
            )
            return
        }

        if succeeded {
            lastSyncDate = max(lastSyncDate ?? .distantPast, endDate)
            switch kind {
            case 1:
                lastImportDate = endDate
                destructiveSharingReady = true
                recoverPendingExpenseTransfers()
            case 2:
                lastExportDate = endDate
            default:
                break
            }
            lastCloudEventDescription = String(
                localized: "\(eventName) completed",
                comment: "CloudKit event status"
            )
            if diagnostic?.kind == .cloudKit {
                diagnostic = nil
            }
        } else {
            syncActivity = .failed
            if kind == 0 || kind == 1 {
                destructiveSharingReady = false
            }
            let message = errorMessage
                ?? String(localized: "CloudKit reported an unknown error.", comment: "Sync error")
            diagnostic = PersistenceDiagnostic(kind: .cloudKit, message: message)
            lastCloudEventDescription = String(
                localized: "\(eventName) failed",
                comment: "CloudKit event status"
            )
        }
    }

    private func applicationSupportURL() -> URL {
        Self.resolvedApplicationSupportURL(override: applicationSupportDirectoryOverride)
    }

    private static func resolvedApplicationSupportURL(override: URL?) -> URL {
        if let override {
            return override
        }
        let created = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = created
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? NSPersistentContainer.defaultDirectoryURL()
        return base.appendingPathComponent("HowMuch", isDirectory: true)
    }
}

extension NSPersistentStoreCoordinator {
    fileprivate func persistentStore(for url: URL) -> NSPersistentStore? {
        persistentStores.first { $0.url == url }
    }
}
