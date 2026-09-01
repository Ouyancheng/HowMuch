import CoreData
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let howMuchArchive = UTType(exportedAs: "com.howmuch.app.archive", conformingTo: .package)
}

enum ArchiveImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge
    case copies
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge:
            String(localized: "Merge by UUID", comment: "Archive import mode")
        case .copies:
            String(localized: "Import as Copies", comment: "Archive import mode")
        case .replace:
            String(localized: "Replace Matching", comment: "Archive import mode")
        }
    }
}

enum ReportingCurrencyUpdateMode: Sendable {
    case keepHistoricalValues
    case recalculateStoredFigures
}

enum HowMuchArchiveError: LocalizedError, Equatable {
    case invalidPackage(String)
    case unsupportedVersion(Int)
    case invalidCount(String)
    case invalidValue(String)
    case duplicateUUID(String)
    case missingReference(String)
    case unsafePath(String)
    case privateStoreUnavailable
    case sharedUUIDCollision(String)
    case incompatibleUUIDMapping(String)
    case currencyConversionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let detail):
            String(localized: "This HowMuch archive is invalid: \(detail)", comment: "Archive error")
        case .unsupportedVersion(let version):
            String(localized: "Archive version \(version) is not supported.", comment: "Archive error")
        case .invalidCount(let detail):
            String(localized: "Archive record counts do not match: \(detail)", comment: "Archive error")
        case .invalidValue(let detail):
            String(localized: "The archive contains an invalid value: \(detail)", comment: "Archive error")
        case .duplicateUUID(let value):
            String(localized: "The archive contains a duplicate UUID: \(value)", comment: "Archive error")
        case .missingReference(let value):
            String(localized: "The archive contains a missing reference: \(value)", comment: "Archive error")
        case .unsafePath(let value):
            String(localized: "The archive contains an unsafe path: \(value)", comment: "Archive error")
        case .privateStoreUnavailable:
            String(localized: "The private data store is unavailable.", comment: "Archive error")
        case .sharedUUIDCollision(let value):
            String(localized: "UUID \(value) already exists in shared data and cannot be imported privately.", comment: "Archive error")
        case .incompatibleUUIDMapping(let value):
            String(localized: "UUID \(value) belongs to a different ledger and cannot be merged.", comment: "Archive error")
        case .currencyConversionUnavailable(let value):
            String(localized: "No default exchange rate is available for \(value). No currency values were changed.", comment: "Currency error")
        }
    }
}

enum HowMuchArchiveLimits {
    static let maximumManifestBytes = 64 * 1024
    static let maximumRecordsBytes = 25 * 1024 * 1024
    static let maximumCSVBytes = 25 * 1024 * 1024
    static let maximumReceiptBytes = ReceiptDraft.maxByteCount
    static let maximumAggregateReceiptBytes = 100 * 1024 * 1024
    static let maximumPackageBytes = 150 * 1024 * 1024
    static let maximumReceiptCount = 5_000
    static let maximumLedgerCount = 10_000
    static let maximumCategoryCount = 50_000
    static let maximumPaymentMethodCount = 50_000
    static let maximumExpenseCount = 100_000
    static let maximumRecordCount = 210_000
    static let maximumMoneySignificantDigits = 38
    static let maximumMoneyScale = 38
}

struct HowMuchArchiveManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let currentSourceFormatIdentifier = "com.howmuch.app.archive"

    var formatVersion: Int
    var createdAt: String
    var includesReceipts: Bool
    var ledgerCount: Int
    var categoryCount: Int
    var paymentMethodCount: Int
    var expenseCount: Int
    var receiptCount: Int
    var appVersion: String?
    var build: String?
    var sourceFormatIdentifier: String?
}

struct HowMuchArchiveRecords: Codable, Equatable, Sendable {
    struct LedgerRecord: Codable, Equatable, Sendable {
        var uuid: UUID
        var name: String
        var kind: Int16
        var reportingCurrency: String
        var createdAt: String
        var updatedAt: String
    }

    struct CategoryRecord: Codable, Equatable, Sendable {
        var uuid: UUID
        var ledgerUUID: UUID
        var name: String
        var symbolName: String
        var colorHex: String
        var sortOrder: Int16
        var isArchived: Bool
        var createdAt: String
    }

    struct PaymentMethodRecord: Codable, Equatable, Sendable {
        var uuid: UUID
        var ledgerUUID: UUID
        var name: String
        var billingCurrency: String
        var kind: Int16
        var isArchived: Bool
        var createdAt: String
    }

    struct ExpenseRecord: Codable, Equatable, Sendable {
        var uuid: UUID
        var ledgerUUID: UUID
        var categoryUUID: UUID?
        var paymentMethodUUID: UUID?
        var occurredAt: String
        var merchant: String
        var note: String
        var spendAmount: String
        var spendCurrency: String
        var chargedAmount: String
        var chargedCurrency: String
        var reportingAmount: String
        var reportingCurrency: String
        var createdAt: String
        var updatedAt: String
        var createdByName: String
        var receiptPath: String?
        var receiptFileName: String?
        var receiptContentType: String?
    }

    var ledgers: [LedgerRecord]
    var categories: [CategoryRecord]
    var paymentMethods: [PaymentMethodRecord]
    var expenses: [ExpenseRecord]
}

struct HowMuchArchiveSnapshot: Sendable {
    var records: HowMuchArchiveRecords
    var receipts: [String: Data]
    var createdAt: Date
    var includesReceipts: Bool
}

struct HowMuchEncodedArchive: Sendable {
    var manifest: Data
    var records: Data
    var csv: Data
    var receipts: [String: Data]
}

struct HowMuchValidatedArchive: Sendable {
    var manifest: HowMuchArchiveManifest
    var records: HowMuchArchiveRecords
    var receipts: [String: ReceiptDraft]
}

struct HowMuchImportPreview: Identifiable, Sendable {
    var archive: HowMuchValidatedArchive
    var existingRecordCount: Int
    var id: String { archive.manifest.createdAt }

    var summary: String {
        let manifest = archive.manifest
        return String(
            localized: "\(manifest.ledgerCount) ledgers, \(manifest.expenseCount) expenses, \(manifest.receiptCount) receipts. \(existingRecordCount) UUIDs already exist.",
            comment: "Archive import preview"
        )
    }
}

struct HowMuchArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.howMuchArchive] }
    static var writableContentTypes: [UTType] { [.howMuchArchive] }

    private var package: HowMuchEncodedArchive

    init(package: HowMuchEncodedArchive) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        package = try Self.package(from: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        packageWrapper()
    }

    func packageWrapper() -> FileWrapper {
        var children: [String: FileWrapper] = [
            "manifest.json": FileWrapper(regularFileWithContents: package.manifest),
            "records.json": FileWrapper(regularFileWithContents: package.records),
            "expenses.csv": FileWrapper(regularFileWithContents: package.csv)
        ]
        let receiptChildren = Dictionary(uniqueKeysWithValues: package.receipts.map {
            (URL(fileURLWithPath: $0.key).lastPathComponent, FileWrapper(regularFileWithContents: $0.value))
        })
        children["receipts"] = FileWrapper(directoryWithFileWrappers: receiptChildren)
        return FileWrapper(directoryWithFileWrappers: children)
    }

    static func loadPackage(from url: URL) throws -> HowMuchEncodedArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        try preflightPackage(at: url)
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try package(from: wrapper)
    }

    static func package(from wrapper: FileWrapper) throws -> HowMuchEncodedArchive {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw HowMuchArchiveError.invalidPackage("The document is not a package.")
        }
        let allowed = Set(["manifest.json", "records.json", "expenses.csv", "receipts"])
        guard Set(children.keys).isSubset(of: allowed),
              let manifest = children["manifest.json"]?.regularFileContents,
              let records = children["records.json"]?.regularFileContents,
              let csv = children["expenses.csv"]?.regularFileContents,
              children["receipts"]?.isDirectory == true else {
            throw HowMuchArchiveError.invalidPackage("Required files are missing or unknown files are present.")
        }
        let receiptWrappers = children["receipts"]?.fileWrappers ?? [:]
        guard receiptWrappers.values.allSatisfy(\.isRegularFile) else {
            throw HowMuchArchiveError.invalidPackage("The receipts folder contains a nested item.")
        }
        guard receiptWrappers.count <= HowMuchArchiveLimits.maximumReceiptCount else {
            throw HowMuchArchiveError.invalidCount("too many receipts")
        }
        try validateEncodedSizes(
            manifest: manifest,
            records: records,
            csv: csv,
            receipts: receiptWrappers.compactMapValues(\.regularFileContents)
        )
        return HowMuchEncodedArchive(
            manifest: manifest,
            records: records,
            csv: csv,
            receipts: Dictionary(uniqueKeysWithValues: receiptWrappers.compactMap { name, wrapper in
                wrapper.regularFileContents.map { ("receipts/\(name)", $0) }
            })
        )
    }

    private static func preflightPackage(at url: URL) throws {
        let manager = FileManager.default
        let rootValues = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw HowMuchArchiveError.invalidPackage("The document is not a regular package.")
        }

        let requiredFiles = Set(["manifest.json", "records.json", "expenses.csv"])
        let allowedRootEntries = requiredFiles.union(["receipts"])
        var foundFiles: Set<String> = []
        var foundReceiptsDirectory = false
        var receiptCount = 0
        var receiptBytes = 0
        var packageBytes = 0
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw HowMuchArchiveError.invalidPackage("The package cannot be inspected.")
        }

        for case let itemURL as URL in enumerator {
            let components: [String]
            switch enumerator.level {
            case 1:
                components = [itemURL.lastPathComponent]
            case 2:
                components = [
                    itemURL.deletingLastPathComponent().lastPathComponent,
                    itemURL.lastPathComponent
                ]
            default:
                throw HowMuchArchiveError.invalidPackage("Nested package item: \(itemURL.lastPathComponent)")
            }
            let relative = components.joined(separator: "/")
            let values = try itemURL.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true else {
                throw HowMuchArchiveError.unsafePath(relative)
            }
            guard let rootName = components.first,
                  allowedRootEntries.contains(rootName) else {
                throw HowMuchArchiveError.invalidPackage("Unexpected item: \(relative)")
            }

            if components.count == 1 {
                if requiredFiles.contains(rootName) {
                    guard values.isRegularFile == true else {
                        throw HowMuchArchiveError.invalidPackage("\(rootName) is not a regular file.")
                    }
                    foundFiles.insert(rootName)
                    let size = values.fileSize ?? 0
                    try validateTopLevelSize(size, named: rootName)
                    packageBytes = try checkedByteSum(packageBytes, size)
                } else {
                    guard rootName == "receipts", values.isDirectory == true else {
                        throw HowMuchArchiveError.invalidPackage("The receipts item is not a directory.")
                    }
                    foundReceiptsDirectory = true
                }
                continue
            }

            guard components.count == 2, components[0] == "receipts",
                  values.isRegularFile == true else {
                throw HowMuchArchiveError.invalidPackage("Nested package item: \(relative)")
            }
            let size = values.fileSize ?? 0
            guard size > 0, size <= HowMuchArchiveLimits.maximumReceiptBytes else {
                throw HowMuchArchiveError.invalidPackage("Receipt size exceeds the allowed limit.")
            }
            receiptCount += 1
            guard receiptCount <= HowMuchArchiveLimits.maximumReceiptCount else {
                throw HowMuchArchiveError.invalidCount("too many receipts")
            }
            receiptBytes = try checkedByteSum(receiptBytes, size)
            guard receiptBytes <= HowMuchArchiveLimits.maximumAggregateReceiptBytes else {
                throw HowMuchArchiveError.invalidPackage("Receipts exceed the aggregate size limit.")
            }
            packageBytes = try checkedByteSum(packageBytes, size)
            guard packageBytes <= HowMuchArchiveLimits.maximumPackageBytes else {
                throw HowMuchArchiveError.invalidPackage("The package exceeds the size limit.")
            }
        }
        guard foundFiles == requiredFiles, foundReceiptsDirectory else {
            throw HowMuchArchiveError.invalidPackage("Required files are missing.")
        }
    }

    private static func validateTopLevelSize(_ size: Int, named name: String) throws {
        let maximum: Int
        switch name {
        case "manifest.json": maximum = HowMuchArchiveLimits.maximumManifestBytes
        case "records.json": maximum = HowMuchArchiveLimits.maximumRecordsBytes
        case "expenses.csv": maximum = HowMuchArchiveLimits.maximumCSVBytes
        default: throw HowMuchArchiveError.invalidPackage("Unexpected item: \(name)")
        }
        guard size > 0, size <= maximum else {
            throw HowMuchArchiveError.invalidPackage("\(name) exceeds the size limit.")
        }
    }

    fileprivate static func validateEncodedSizes(
        manifest: Data,
        records: Data,
        csv: Data,
        receipts: [String: Data]
    ) throws {
        try validateTopLevelSize(manifest.count, named: "manifest.json")
        try validateTopLevelSize(records.count, named: "records.json")
        try validateTopLevelSize(csv.count, named: "expenses.csv")
        guard receipts.count <= HowMuchArchiveLimits.maximumReceiptCount else {
            throw HowMuchArchiveError.invalidCount("too many receipts")
        }
        var receiptBytes = 0
        var packageBytes = try checkedByteSum(manifest.count, records.count)
        packageBytes = try checkedByteSum(packageBytes, csv.count)
        for (path, data) in receipts {
            guard data.count > 0, data.count <= HowMuchArchiveLimits.maximumReceiptBytes else {
                throw HowMuchArchiveError.invalidPackage("Receipt \(path) exceeds the size limit.")
            }
            receiptBytes = try checkedByteSum(receiptBytes, data.count)
            packageBytes = try checkedByteSum(packageBytes, data.count)
        }
        guard receiptBytes <= HowMuchArchiveLimits.maximumAggregateReceiptBytes else {
            throw HowMuchArchiveError.invalidPackage("Receipts exceed the aggregate size limit.")
        }
        guard packageBytes <= HowMuchArchiveLimits.maximumPackageBytes else {
            throw HowMuchArchiveError.invalidPackage("The package exceeds the size limit.")
        }
    }

    private static func checkedByteSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw HowMuchArchiveError.invalidPackage("Package size overflow.")
        }
        return sum
    }
}

enum HowMuchArchiveCodec {
    static func encode(_ snapshot: HowMuchArchiveSnapshot) throws -> HowMuchEncodedArchive {
        let records = snapshot.records
        try validateRecords(records)
        let manifest = HowMuchArchiveManifest(
            formatVersion: HowMuchArchiveManifest.currentVersion,
            createdAt: dateString(snapshot.createdAt),
            includesReceipts: snapshot.includesReceipts,
            ledgerCount: records.ledgers.count,
            categoryCount: records.categories.count,
            paymentMethodCount: records.paymentMethods.count,
            expenseCount: records.expenses.count,
            receiptCount: snapshot.receipts.count,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            sourceFormatIdentifier: HowMuchArchiveManifest.currentSourceFormatIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let package = HowMuchEncodedArchive(
            manifest: try encoder.encode(manifest),
            records: try encoder.encode(records),
            csv: expensesCSV(records.expenses),
            receipts: snapshot.receipts
        )
        try HowMuchArchiveDocument.validateEncodedSizes(
            manifest: package.manifest,
            records: package.records,
            csv: package.csv,
            receipts: package.receipts
        )
        return package
    }

    static func validate(_ package: HowMuchEncodedArchive) async throws -> HowMuchValidatedArchive {
        try HowMuchArchiveDocument.validateEncodedSizes(
            manifest: package.manifest,
            records: package.records,
            csv: package.csv,
            receipts: package.receipts
        )
        let decoder = JSONDecoder()
        let manifest: HowMuchArchiveManifest
        let records: HowMuchArchiveRecords
        do {
            manifest = try decoder.decode(HowMuchArchiveManifest.self, from: package.manifest)
            records = try decoder.decode(HowMuchArchiveRecords.self, from: package.records)
        } catch {
            throw HowMuchArchiveError.invalidPackage(error.localizedDescription)
        }
        guard manifest.formatVersion == HowMuchArchiveManifest.currentVersion else {
            throw HowMuchArchiveError.unsupportedVersion(manifest.formatVersion)
        }
        if let sourceFormatIdentifier = manifest.sourceFormatIdentifier,
           sourceFormatIdentifier != HowMuchArchiveManifest.currentSourceFormatIdentifier {
            throw HowMuchArchiveError.invalidValue("manifest.sourceFormatIdentifier")
        }
        if manifest.appVersion?.isEmpty == true || manifest.build?.isEmpty == true {
            throw HowMuchArchiveError.invalidValue("manifest application version")
        }
        _ = try parseDate(manifest.createdAt, field: "manifest.createdAt")
        try validateCounts(manifest)
        guard manifest.ledgerCount == records.ledgers.count,
              manifest.categoryCount == records.categories.count,
              manifest.paymentMethodCount == records.paymentMethods.count,
              manifest.expenseCount == records.expenses.count,
              manifest.receiptCount == package.receipts.count else {
            throw HowMuchArchiveError.invalidCount("manifest.json")
        }
        if !manifest.includesReceipts, !package.receipts.isEmpty {
            throw HowMuchArchiveError.invalidCount("receipts are present when includesReceipts is false")
        }

        try validateRecords(records)
        var validatedReceipts: [String: ReceiptDraft] = [:]
        let referencedPaths = Set(records.expenses.compactMap(\.receiptPath))
        guard referencedPaths == Set(package.receipts.keys) else {
            throw HowMuchArchiveError.invalidCount("receipt references")
        }
        for expense in records.expenses {
            guard let path = expense.receiptPath else {
                if expense.receiptContentType != nil || expense.receiptFileName != nil {
                    throw HowMuchArchiveError.invalidValue("receipt metadata without receipt data")
                }
                continue
            }
            try validateReceiptPath(path, expenseUUID: expense.uuid)
            guard let data = package.receipts[path],
                  let contentType = expense.receiptContentType,
                  let fileName = expense.receiptFileName else {
                throw HowMuchArchiveError.missingReference(path)
            }
            let validated = try await ReceiptDraft.prepare(
                data: data,
                fileName: fileName,
                typeIdentifier: contentType
            )
            validatedReceipts[path] = validated
        }
        return HowMuchValidatedArchive(manifest: manifest, records: records, receipts: validatedReceipts)
    }

    static func expensesCSV(_ expenses: [HowMuchArchiveRecords.ExpenseRecord]) -> Data {
        let columns = [
            "uuid", "ledger_uuid", "category_uuid", "payment_method_uuid", "occurred_at",
            "merchant", "note", "spend_amount", "spend_currency", "charged_amount",
            "charged_currency", "reporting_amount", "reporting_currency", "created_at",
            "updated_at", "created_by_name", "receipt_path"
        ]
        var rows = [columns.map(csvField).joined(separator: ",")]
        for expense in expenses {
            rows.append([
                expense.uuid.uuidString, expense.ledgerUUID.uuidString,
                expense.categoryUUID?.uuidString ?? "", expense.paymentMethodUUID?.uuidString ?? "",
                expense.occurredAt, neutralizedCSVUserText(expense.merchant),
                neutralizedCSVUserText(expense.note), expense.spendAmount,
                expense.spendCurrency, expense.chargedAmount, expense.chargedCurrency,
                expense.reportingAmount, expense.reportingCurrency, expense.createdAt,
                expense.updatedAt, neutralizedCSVUserText(expense.createdByName),
                expense.receiptPath ?? ""
            ].map(csvField).joined(separator: ","))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter.archiveFormatter.string(from: date)
    }

    static func decimalString(_ number: NSDecimalNumber?) -> String {
        (number ?? .zero).stringValue
    }

    static func parseDecimal(_ value: String, field: String) throws -> Decimal {
        guard value.range(
            of: #"^(?:(?:[1-9][0-9]*)(?:\.[0-9]*[1-9])?|0\.[0-9]*[1-9])$"#,
            options: .regularExpression
        ) != nil else {
            throw HowMuchArchiveError.invalidValue(field)
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let digits = value.filter(\.isNumber)
        let significantDigits = digits.drop(while: { $0 == "0" }).count
        let scale = components.count == 2 ? components[1].count : 0
        guard components.count <= 2,
              significantDigits > 0,
              significantDigits <= HowMuchArchiveLimits.maximumMoneySignificantDigits,
              scale <= HowMuchArchiveLimits.maximumMoneyScale,
              let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: result) != .notANumber,
              NSDecimalNumber(decimal: result).stringValue == value else {
            throw HowMuchArchiveError.invalidValue(field)
        }
        return result
    }

    static func decimalNumber(_ value: String, field: String) throws -> NSDecimalNumber {
        let decimal = try parseDecimal(value, field: field)
        let number = NSDecimalNumber(decimal: decimal)
        guard number.stringValue == value else {
            throw HowMuchArchiveError.invalidValue(field)
        }
        return number
    }

    private static func validateRecords(_ records: HowMuchArchiveRecords) throws {
        try requireUnique(
            records.ledgers.map(\.uuid)
                + records.categories.map(\.uuid)
                + records.paymentMethods.map(\.uuid)
                + records.expenses.map(\.uuid)
        )

        let ledgerIDs = Set(records.ledgers.map(\.uuid))
        let categories = Dictionary(uniqueKeysWithValues: records.categories.map { ($0.uuid, $0) })
        let methods = Dictionary(uniqueKeysWithValues: records.paymentMethods.map { ($0.uuid, $0) })
        for ledger in records.ledgers {
            guard LedgerKind(rawValue: ledger.kind) != nil else {
                throw HowMuchArchiveError.invalidValue("ledger.kind")
            }
            try validateCurrency(ledger.reportingCurrency, field: "ledger.reportingCurrency")
            _ = try parseDate(ledger.createdAt, field: "ledger.createdAt")
            _ = try parseDate(ledger.updatedAt, field: "ledger.updatedAt")
        }
        for category in records.categories {
            guard ledgerIDs.contains(category.ledgerUUID) else {
                throw HowMuchArchiveError.missingReference(category.ledgerUUID.uuidString)
            }
            _ = try parseDate(category.createdAt, field: "category.createdAt")
        }
        for method in records.paymentMethods {
            guard ledgerIDs.contains(method.ledgerUUID) else {
                throw HowMuchArchiveError.missingReference(method.ledgerUUID.uuidString)
            }
            guard PaymentKind(rawValue: method.kind) != nil else {
                throw HowMuchArchiveError.invalidValue("paymentMethod.kind")
            }
            try validateCurrency(method.billingCurrency, field: "paymentMethod.billingCurrency")
            _ = try parseDate(method.createdAt, field: "paymentMethod.createdAt")
        }
        for expense in records.expenses {
            guard ledgerIDs.contains(expense.ledgerUUID) else {
                throw HowMuchArchiveError.missingReference(expense.ledgerUUID.uuidString)
            }
            if let categoryUUID = expense.categoryUUID {
                guard categories[categoryUUID]?.ledgerUUID == expense.ledgerUUID else {
                    throw HowMuchArchiveError.missingReference(categoryUUID.uuidString)
                }
            }
            if let methodUUID = expense.paymentMethodUUID {
                guard methods[methodUUID]?.ledgerUUID == expense.ledgerUUID else {
                    throw HowMuchArchiveError.missingReference(methodUUID.uuidString)
                }
            }
            _ = try parseDate(expense.occurredAt, field: "expense.occurredAt")
            _ = try parseDate(expense.createdAt, field: "expense.createdAt")
            _ = try parseDate(expense.updatedAt, field: "expense.updatedAt")
            _ = try decimalNumber(expense.spendAmount, field: "expense.spendAmount")
            _ = try decimalNumber(expense.chargedAmount, field: "expense.chargedAmount")
            _ = try decimalNumber(expense.reportingAmount, field: "expense.reportingAmount")
            try validateCurrency(expense.spendCurrency, field: "expense.spendCurrency")
            try validateCurrency(expense.chargedCurrency, field: "expense.chargedCurrency")
            try validateCurrency(expense.reportingCurrency, field: "expense.reportingCurrency")
            if let path = expense.receiptPath {
                try validateReceiptPath(path, expenseUUID: expense.uuid)
            }
        }
    }

    private static func requireUnique(_ values: [UUID]) throws {
        var seen: Set<UUID> = []
        for value in values where !seen.insert(value).inserted {
            throw HowMuchArchiveError.duplicateUUID(value.uuidString)
        }
    }

    private static func validateCounts(_ manifest: HowMuchArchiveManifest) throws {
        let counts = [
            manifest.ledgerCount,
            manifest.categoryCount,
            manifest.paymentMethodCount,
            manifest.expenseCount,
            manifest.receiptCount
        ]
        guard counts.allSatisfy({ $0 >= 0 }),
              manifest.ledgerCount <= HowMuchArchiveLimits.maximumLedgerCount,
              manifest.categoryCount <= HowMuchArchiveLimits.maximumCategoryCount,
              manifest.paymentMethodCount <= HowMuchArchiveLimits.maximumPaymentMethodCount,
              manifest.expenseCount <= HowMuchArchiveLimits.maximumExpenseCount,
              manifest.receiptCount <= HowMuchArchiveLimits.maximumReceiptCount else {
            throw HowMuchArchiveError.invalidCount("manifest limits")
        }
        guard counts.dropLast().reduce(0, +) <= HowMuchArchiveLimits.maximumRecordCount else {
            throw HowMuchArchiveError.invalidCount("total record limit")
        }
    }

    private static func validateCurrency(_ value: String, field: String) throws {
        let supported = Set(Locale.commonISOCurrencyCodes)
        guard value.count == 3, value == value.uppercased(), supported.contains(value) else {
            throw HowMuchArchiveError.invalidValue(field)
        }
    }

    private static func parseDate(_ value: String, field: String) throws -> Date {
        guard let date = ISO8601DateFormatter.archiveFormatter.date(from: value) else {
            throw HowMuchArchiveError.invalidValue(field)
        }
        return date
    }

    private static func validateReceiptPath(_ path: String, expenseUUID: UUID) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "receipts",
              !path.contains(".."), !path.contains("\\"), !path.hasPrefix("/"),
              URL(fileURLWithPath: String(components[1])).deletingPathExtension().lastPathComponent
                == expenseUUID.uuidString else {
            throw HowMuchArchiveError.unsafePath(path)
        }
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func neutralizedCSVUserText(_ value: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard let first = value.unicodeScalars.first(where: { !ignored.contains($0) }),
              "=+-@".unicodeScalars.contains(first) else {
            return value
        }
        return "'" + value
    }
}

private extension ISO8601DateFormatter {
    static var archiveFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

extension PersistenceController {
    func makeArchiveSnapshot(includeReceipts: Bool = true) throws -> HowMuchArchiveSnapshot {
        let ledgerRequest = Ledger.fetchRequest()
        ledgerRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Ledger.createdAt, ascending: true)]
        let ledgers = try viewContext.fetch(ledgerRequest).filter { !$0.isDeleted }
        let ledgerIDs = Set(ledgers.map(\.objectID))

        let categories = try viewContext.fetch(Category.fetchRequest())
            .filter { $0.ledger.map { ledgerIDs.contains($0.objectID) } == true }
        let methods = try viewContext.fetch(PaymentMethod.fetchRequest())
            .filter { $0.ledger.map { ledgerIDs.contains($0.objectID) } == true }
        let expenses = try viewContext.fetch(Expense.fetchRequest())
            .filter { $0.ledger.map { ledgerIDs.contains($0.objectID) } == true }
        guard ledgers.allSatisfy({ $0.uuid != nil }),
              categories.allSatisfy({ $0.uuid != nil && $0.ledger?.uuid != nil }),
              methods.allSatisfy({ $0.uuid != nil && $0.ledger?.uuid != nil }),
              expenses.allSatisfy({ $0.uuid != nil && $0.ledger?.uuid != nil }) else {
            throw HowMuchArchiveError.invalidValue("A stored record has no UUID.")
        }

        var receipts: [String: Data] = [:]
        let expenseRecords = try expenses.map { expense -> HowMuchArchiveRecords.ExpenseRecord in
            guard let uuid = expense.uuid, let ledgerUUID = expense.ledger?.uuid else {
                throw HowMuchArchiveError.invalidValue("A stored expense has no UUID.")
            }
            let storedReceiptData = expense.receiptData
            let hasReceiptData = storedReceiptData?.isEmpty == false
            let hasReceiptFileName = expense.receiptFileName?.isEmpty == false
            let hasReceiptContentType = expense.receiptContentType?.isEmpty == false
            guard hasReceiptData == (hasReceiptFileName && hasReceiptContentType),
                  hasReceiptFileName == hasReceiptContentType else {
                throw HowMuchArchiveError.invalidValue(
                    "Expense \(uuid.uuidString) has incomplete receipt data or metadata."
                )
            }
            var receiptPath: String?
            if includeReceipts, let data = storedReceiptData, !data.isEmpty {
                let type = expense.receiptContentType.flatMap(UTType.init)
                let ext = type?.preferredFilenameExtension
                    ?? URL(fileURLWithPath: expense.wrappedReceiptFileName).pathExtension
                let safeExtension = ext.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) == nil ? "dat" : ext
                let path = "receipts/\(uuid.uuidString).\(safeExtension.lowercased())"
                receipts[path] = data
                receiptPath = path
            }
            return .init(
                uuid: uuid,
                ledgerUUID: ledgerUUID,
                categoryUUID: expense.category?.uuid,
                paymentMethodUUID: expense.paymentMethod?.uuid,
                occurredAt: HowMuchArchiveCodec.dateString(expense.occurredAt ?? .distantPast),
                merchant: expense.merchant ?? "",
                note: expense.note ?? "",
                spendAmount: HowMuchArchiveCodec.decimalString(expense.spendAmount),
                spendCurrency: expense.wrappedSpendCurrency.uppercased(),
                chargedAmount: HowMuchArchiveCodec.decimalString(expense.chargedAmount),
                chargedCurrency: expense.wrappedChargedCurrency.uppercased(),
                reportingAmount: HowMuchArchiveCodec.decimalString(expense.reportingAmount),
                reportingCurrency: expense.wrappedReportingCurrency.uppercased(),
                createdAt: HowMuchArchiveCodec.dateString(expense.createdAt ?? .distantPast),
                updatedAt: HowMuchArchiveCodec.dateString(expense.updatedAt ?? .distantPast),
                createdByName: expense.createdByName ?? "",
                receiptPath: receiptPath,
                receiptFileName: receiptPath == nil ? nil : expense.receiptFileName,
                receiptContentType: receiptPath == nil ? nil : expense.receiptContentType
            )
        }
        let records = HowMuchArchiveRecords(
            ledgers: ledgers.compactMap { ledger in
                guard let uuid = ledger.uuid else { return nil }
                return .init(
                    uuid: uuid,
                    name: ledger.name ?? "",
                    kind: ledger.kind,
                    reportingCurrency: ledger.wrappedReportingCurrency.uppercased(),
                    createdAt: HowMuchArchiveCodec.dateString(ledger.createdAt ?? .distantPast),
                    updatedAt: HowMuchArchiveCodec.dateString(ledger.updatedAt ?? .distantPast)
                )
            },
            categories: categories.compactMap { category in
                guard let uuid = category.uuid, let ledgerUUID = category.ledger?.uuid else { return nil }
                return .init(
                    uuid: uuid,
                    ledgerUUID: ledgerUUID,
                    name: category.name ?? "",
                    symbolName: category.symbolName ?? "tag",
                    colorHex: category.colorHex ?? "5B8DEF",
                    sortOrder: category.sortOrder,
                    isArchived: category.isArchived,
                    createdAt: HowMuchArchiveCodec.dateString(category.createdAt ?? .distantPast)
                )
            },
            paymentMethods: methods.compactMap { method in
                guard let uuid = method.uuid, let ledgerUUID = method.ledger?.uuid else { return nil }
                return .init(
                    uuid: uuid,
                    ledgerUUID: ledgerUUID,
                    name: method.name ?? "",
                    billingCurrency: method.wrappedBillingCurrency.uppercased(),
                    kind: method.kind,
                    isArchived: method.isArchived,
                    createdAt: HowMuchArchiveCodec.dateString(method.createdAt ?? .distantPast)
                )
            },
            expenses: expenseRecords
        )
        return HowMuchArchiveSnapshot(
            records: records,
            receipts: receipts,
            createdAt: Date(),
            includesReceipts: includeReceipts
        )
    }

    func previewImport(_ archive: HowMuchValidatedArchive) throws -> HowMuchImportPreview {
        let existing = Set(try viewContext.fetch(Ledger.fetchRequest()).compactMap(\.uuid))
            .union(try viewContext.fetch(Category.fetchRequest()).compactMap(\.uuid))
            .union(try viewContext.fetch(PaymentMethod.fetchRequest()).compactMap(\.uuid))
            .union(try viewContext.fetch(Expense.fetchRequest()).compactMap(\.uuid))
        let imported = Set(archive.records.ledgers.map(\.uuid))
            .union(archive.records.categories.map(\.uuid))
            .union(archive.records.paymentMethods.map(\.uuid))
            .union(archive.records.expenses.map(\.uuid))
        return HowMuchImportPreview(archive: archive, existingRecordCount: existing.intersection(imported).count)
    }

    func importArchive(_ archive: HowMuchValidatedArchive, mode: ArchiveImportMode) async throws {
        guard let privateStore else { throw HowMuchArchiveError.privateStoreUnavailable }
        let privateStoreIdentifier = privateStore.identifier
        let context = container.newBackgroundContext()
        context.name = "archiveImporter"
        context.transactionAuthor = "howmuch.archive"
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        try await context.perform {
            guard let importStore = context.persistentStoreCoordinator?.persistentStores.first(where: {
                $0.identifier == privateStoreIdentifier
            }) else {
                throw HowMuchArchiveError.privateStoreUnavailable
            }
            let existingLedgers: [UUID: Ledger]
            let existingCategories: [UUID: Category]
            let existingMethods: [UUID: PaymentMethod]
            let existingExpenses: [UUID: Expense]
            if mode == .copies {
                // Copies intentionally do not inspect or reuse UUID dictionaries.
                existingLedgers = [:]
                existingCategories = [:]
                existingMethods = [:]
                existingExpenses = [:]
            } else {
                existingLedgers = try Self.existingByUUID(Ledger.fetchRequest(), in: context)
                existingCategories = try Self.existingByUUID(Category.fetchRequest(), in: context)
                existingMethods = try Self.existingByUUID(PaymentMethod.fetchRequest(), in: context)
                existingExpenses = try Self.existingByUUID(Expense.fetchRequest(), in: context)
                try Self.preflightMerge(
                    archive: archive,
                    privateStore: importStore,
                    ledgers: existingLedgers,
                    categories: existingCategories,
                    methods: existingMethods,
                    expenses: existingExpenses
                )
            }
            var ledgerMap: [UUID: Ledger] = [:]
            var categoryMap: [UUID: Category] = [:]
            var methodMap: [UUID: PaymentMethod] = [:]
            var expenseMap: [UUID: Expense] = [:]
            var created: Set<NSManagedObjectID> = []

            for record in archive.records.ledgers {
                let object = try Self.importObject(
                    sourceUUID: record.uuid, existing: existingLedgers, mode: mode,
                    context: context, store: importStore, created: &created
                ) { Ledger(context: context) }
                ledgerMap[record.uuid] = object
                if Self.shouldWrite(object, created: created, mode: mode) {
                    object.uuid = mode == .copies ? UUID() : record.uuid
                    object.name = record.name
                    object.kind = record.kind
                    object.reportingCurrency = record.reportingCurrency
                    object.createdAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.createdAt)
                        .unwrapArchiveDate(record.createdAt)
                    object.updatedAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.updatedAt)
                        .unwrapArchiveDate(record.updatedAt)
                }
            }
            for record in archive.records.categories {
                let object = try Self.importObject(
                    sourceUUID: record.uuid, existing: existingCategories, mode: mode,
                    context: context, store: importStore, created: &created
                ) { Category(context: context) }
                categoryMap[record.uuid] = object
                if Self.shouldWrite(object, created: created, mode: mode) {
                    object.uuid = mode == .copies ? UUID() : record.uuid
                    object.name = record.name
                    object.symbolName = record.symbolName
                    object.colorHex = record.colorHex
                    object.sortOrder = record.sortOrder
                    object.isArchived = record.isArchived
                    object.createdAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.createdAt)
                        .unwrapArchiveDate(record.createdAt)
                }
            }
            for record in archive.records.paymentMethods {
                let object = try Self.importObject(
                    sourceUUID: record.uuid, existing: existingMethods, mode: mode,
                    context: context, store: importStore, created: &created
                ) { PaymentMethod(context: context) }
                methodMap[record.uuid] = object
                if Self.shouldWrite(object, created: created, mode: mode) {
                    object.uuid = mode == .copies ? UUID() : record.uuid
                    object.name = record.name
                    object.billingCurrency = record.billingCurrency
                    object.kind = record.kind
                    object.isArchived = record.isArchived
                    object.createdAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.createdAt)
                        .unwrapArchiveDate(record.createdAt)
                }
            }
            for record in archive.records.expenses {
                let object = try Self.importObject(
                    sourceUUID: record.uuid, existing: existingExpenses, mode: mode,
                    context: context, store: importStore, created: &created
                ) { Expense(context: context) }
                expenseMap[record.uuid] = object
                if Self.shouldWrite(object, created: created, mode: mode) {
                    object.uuid = mode == .copies ? UUID() : record.uuid
                    object.occurredAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.occurredAt)
                        .unwrapArchiveDate(record.occurredAt)
                    object.merchant = record.merchant
                    object.note = record.note
                    object.spendAmount = try HowMuchArchiveCodec.decimalNumber(record.spendAmount, field: "spendAmount")
                    object.spendCurrency = record.spendCurrency
                    object.chargedAmount = try HowMuchArchiveCodec.decimalNumber(record.chargedAmount, field: "chargedAmount")
                    object.chargedCurrency = record.chargedCurrency
                    object.reportingAmount = try HowMuchArchiveCodec.decimalNumber(record.reportingAmount, field: "reportingAmount")
                    object.reportingCurrency = record.reportingCurrency
                    object.createdAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.createdAt)
                        .unwrapArchiveDate(record.createdAt)
                    object.updatedAt = try ISO8601DateFormatter.archiveFormatter.date(from: record.updatedAt)
                        .unwrapArchiveDate(record.updatedAt)
                    object.createdByName = record.createdByName
                    let receipt = record.receiptPath.flatMap { archive.receipts[$0] }
                    object.receiptData = receipt?.data
                    object.receiptFileName = receipt?.fileName
                    object.receiptContentType = receipt?.contentType
                }
            }

            // Store assignment above intentionally precedes every relationship.
            for record in archive.records.categories {
                guard let object = categoryMap[record.uuid],
                      Self.shouldWrite(object, created: created, mode: mode) else { continue }
                object.ledger = ledgerMap[record.ledgerUUID]
            }
            for record in archive.records.paymentMethods {
                guard let object = methodMap[record.uuid],
                      Self.shouldWrite(object, created: created, mode: mode) else { continue }
                object.ledger = ledgerMap[record.ledgerUUID]
            }
            for record in archive.records.expenses {
                guard let object = expenseMap[record.uuid],
                      Self.shouldWrite(object, created: created, mode: mode) else { continue }
                object.ledger = ledgerMap[record.ledgerUUID]
                object.category = record.categoryUUID.flatMap { categoryMap[$0] }
                object.paymentMethod = record.paymentMethodUUID.flatMap { methodMap[$0] }
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
        invalidateLedgerAccess()
    }

    func updateReportingCurrency(
        for ledger: Ledger,
        to newCurrency: String,
        mode: ReportingCurrencyUpdateMode
    ) throws {
        try assertWritable(ledger)
        let normalized = newCurrency.uppercased()
        guard Set(Locale.commonISOCurrencyCodes).contains(normalized) else {
            throw HowMuchArchiveError.invalidValue("reportingCurrency")
        }
        guard normalized != ledger.wrappedReportingCurrency else { return }
        let recalculations: [(Expense, Decimal)]
        if mode == .recalculateStoredFigures {
            recalculations = try (ledger.expenses ?? []).map { expense in
                let amount: Decimal
                if MoneyMath.currenciesMatch(expense.wrappedChargedCurrency, normalized) {
                    amount = expense.wrappedChargedAmount
                } else if MoneyMath.currenciesMatch(expense.wrappedSpendCurrency, normalized) {
                    amount = expense.wrappedSpendAmount
                } else if MoneyMath.currenciesMatch(expense.wrappedReportingCurrency, normalized) {
                    amount = expense.wrappedReportingAmount
                } else if let converted = DefaultFXRates.convert(
                    expense.wrappedChargedAmount,
                    from: expense.wrappedChargedCurrency,
                    to: normalized
                ) {
                    amount = converted
                } else if let converted = DefaultFXRates.convert(
                    expense.wrappedSpendAmount,
                    from: expense.wrappedSpendCurrency,
                    to: normalized
                ) {
                    amount = converted
                } else {
                    throw HowMuchArchiveError.currencyConversionUnavailable(
                        "\(expense.wrappedChargedCurrency) → \(normalized)"
                    )
                }
                guard amount > 0 else {
                    throw HowMuchArchiveError.invalidValue("reportingAmount")
                }
                return (expense, amount)
            }
        } else {
            recalculations = []
        }
        do {
            if mode == .recalculateStoredFigures {
                for (expense, recalculated) in recalculations {
                    expense.reportingAmount = recalculated as NSDecimalNumber
                    expense.reportingCurrency = normalized
                    expense.updatedAt = Date()
                }
            }
            ledger.reportingCurrency = normalized
            ledger.updatedAt = Date()
            try saveMutationContext()
        } catch {
            viewContext.rollback()
            throw error
        }
    }

    nonisolated private static func existingByUUID<T: NSManagedObject>(
        _ request: NSFetchRequest<T>,
        in context: NSManagedObjectContext
    ) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for object in try context.fetch(request) {
            guard let uuid = object.value(forKey: "uuid") as? UUID else { continue }
            guard result.updateValue(object, forKey: uuid) == nil else {
                throw HowMuchArchiveError.duplicateUUID(uuid.uuidString)
            }
        }
        return result
    }

    nonisolated private static func preflightMerge(
        archive: HowMuchValidatedArchive,
        privateStore: NSPersistentStore,
        ledgers: [UUID: Ledger],
        categories: [UUID: Category],
        methods: [UUID: PaymentMethod],
        expenses: [UUID: Expense]
    ) throws {
        func requirePrivate(_ object: NSManagedObject, uuid: UUID) throws {
            guard object.objectID.persistentStore === privateStore else {
                throw HowMuchArchiveError.sharedUUIDCollision(uuid.uuidString)
            }
        }
        func rejectCrossEntity(_ uuid: UUID, expected: String) throws {
            var actual: [String] = []
            if ledgers[uuid] != nil { actual.append("ledger") }
            if categories[uuid] != nil { actual.append("category") }
            if methods[uuid] != nil { actual.append("payment method") }
            if expenses[uuid] != nil { actual.append("expense") }
            if actual.count > 1 || (actual.first.map { $0 != expected } ?? false) {
                throw HowMuchArchiveError.incompatibleUUIDMapping(uuid.uuidString)
            }
        }
        for record in archive.records.ledgers {
            try rejectCrossEntity(record.uuid, expected: "ledger")
            if let object = ledgers[record.uuid] {
                try requirePrivate(object, uuid: record.uuid)
            }
        }
        for record in archive.records.categories {
            try rejectCrossEntity(record.uuid, expected: "category")
            if let object = categories[record.uuid] {
                try requirePrivate(object, uuid: record.uuid)
                guard object.ledger?.uuid == record.ledgerUUID,
                      object.ledger?.objectID.persistentStore === privateStore else {
                    throw HowMuchArchiveError.incompatibleUUIDMapping(record.uuid.uuidString)
                }
            }
        }
        for record in archive.records.paymentMethods {
            try rejectCrossEntity(record.uuid, expected: "payment method")
            if let object = methods[record.uuid] {
                try requirePrivate(object, uuid: record.uuid)
                guard object.ledger?.uuid == record.ledgerUUID,
                      object.ledger?.objectID.persistentStore === privateStore else {
                    throw HowMuchArchiveError.incompatibleUUIDMapping(record.uuid.uuidString)
                }
            }
        }
        for record in archive.records.expenses {
            try rejectCrossEntity(record.uuid, expected: "expense")
            if let object = expenses[record.uuid] {
                try requirePrivate(object, uuid: record.uuid)
                guard object.ledger?.uuid == record.ledgerUUID,
                      object.ledger?.objectID.persistentStore === privateStore else {
                    throw HowMuchArchiveError.incompatibleUUIDMapping(record.uuid.uuidString)
                }
            }
        }
    }

    nonisolated private static func importObject<T: NSManagedObject>(
        sourceUUID: UUID,
        existing: [UUID: T],
        mode: ArchiveImportMode,
        context: NSManagedObjectContext,
        store: NSPersistentStore,
        created: inout Set<NSManagedObjectID>,
        make: () -> T
    ) throws -> T {
        if mode != .copies, let object = existing[sourceUUID] {
            guard object.objectID.persistentStore === store else {
                throw HowMuchArchiveError.sharedUUIDCollision(sourceUUID.uuidString)
            }
            return object
        }
        let object = make()
        context.assign(object, to: store)
        created.insert(object.objectID)
        return object
    }

    nonisolated private static func shouldWrite(
        _ object: NSManagedObject,
        created: Set<NSManagedObjectID>,
        mode: ArchiveImportMode
    ) -> Bool {
        created.contains(object.objectID) || mode == .replace || mode == .copies
    }

}

private extension Optional where Wrapped == Date {
    func unwrapArchiveDate(_ value: String) throws -> Date {
        guard let self else { throw HowMuchArchiveError.invalidValue(value) }
        return self
    }
}
