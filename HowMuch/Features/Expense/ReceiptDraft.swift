import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ReceiptDraft: Equatable, Sendable {
    static let maxByteCount = 10 * 1024 * 1024
    static let allowedTypes: [UTType] = [.pdf, .image, .jpeg, .png, .heic, .webP]

    var data: Data
    var fileName: String
    var contentType: String

    var isPDF: Bool {
        contentType == UTType.pdf.identifier || fileName.lowercased().hasSuffix(".pdf")
    }

    var displayName: String {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Receipt", comment: "Default receipt filename")
            : name
    }

    static func load(from url: URL) async throws -> ReceiptDraft {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let fileData = try Data(contentsOf: url)
            let data = fileData.withUnsafeBytes { Data($0) }
            try Task.checkCancellation()
            return try make(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier
            )
        }.value
    }

    static func prepare(
        data: Data,
        fileName: String,
        typeIdentifier: String?
    ) async throws -> ReceiptDraft {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try make(data: data, fileName: fileName, typeIdentifier: typeIdentifier)
        }.value
    }

    static func make(data: Data, fileName: String, type: UTType?) throws -> ReceiptDraft {
        try make(data: data, fileName: fileName, typeIdentifier: type?.identifier)
    }

    private static func make(data: Data, fileName: String, typeIdentifier: String?) throws -> ReceiptDraft {
        let type = typeIdentifier.flatMap(UTType.init)
        guard !data.isEmpty else {
            throw ReceiptDraftError.empty
        }
        guard data.count <= maxByteCount else {
            throw ReceiptDraftError.tooLarge
        }

        if type?.conforms(to: .pdf) == true || fileName.lowercased().hasSuffix(".pdf") {
            guard data.starts(with: Data("%PDF".utf8)) else {
                throw ReceiptDraftError.unsupported
            }
            return ReceiptDraft(data: data, fileName: fileName, contentType: UTType.pdf.identifier)
        }

        guard let imageData = compressedImageData(from: data) else {
            throw ReceiptDraftError.unsupported
        }
        guard imageData.count <= maxByteCount else {
            throw ReceiptDraftError.tooLarge
        }
        let name = fileName.isEmpty ? "receipt.jpg" : URL(fileURLWithPath: fileName).deletingPathExtension().appendingPathExtension("jpg").lastPathComponent
        return ReceiptDraft(data: imageData, fileName: name, contentType: UTType.jpeg.identifier)
    }

    func previewFileURL() async throws -> URL {
        let data = data
        let contentType = contentType
        return try await Task.detached(priority: .userInitiated) {
            try ReceiptPreviewFiles.create(data: data, contentType: contentType)
        }.value
    }

    func thumbnailData() async -> Data? {
        guard !isPDF else { return nil }
        let data = data
        return await Task.detached(priority: .utility) {
            ReceiptDraft.compressedImageData(from: data, maxDimension: 160, quality: 0.75)
        }.value
    }

    private static func compressedImageData(from data: Data) -> Data? {
        compressedImageData(from: data, maxDimension: 2400, quality: 0.8)
    }

    private static func compressedImageData(
        from data: Data,
        maxDimension: Int,
        quality: Double
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum ReceiptPreviewFiles {
    static let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HowMuchReceipts", isDirectory: true)
    static let defaultStaleAge: TimeInterval = 24 * 60 * 60

    static func create(
        data: Data,
        contentType: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let pathExtension = UTType(contentType)?.preferredFilenameExtension ?? "dat"
        let url = directoryURL
            .appendingPathComponent("receipt-\(id.uuidString)", isDirectory: false)
            .appendingPathExtension(pathExtension)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return url
    }

    static func cleanup(_ url: URL?) {
        guard let url,
              url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func removeStale(
        now: Date = Date(),
        olderThan age: TimeInterval = defaultStaleAge
    ) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var removed = 0
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) >= age,
               (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

struct LatestSelectionToken: Equatable {
    private(set) var generation: UInt = 0

    mutating func begin() -> UInt {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        candidate == generation
    }
}

enum ReceiptDraftError: LocalizedError {
    case empty
    case tooLarge
    case unsupported

    var errorDescription: String? {
        switch self {
        case .empty:
            String(localized: "The selected file is empty.", comment: "Receipt error")
        case .tooLarge:
            String(localized: "Receipts can be up to 10 MB.", comment: "Receipt error")
        case .unsupported:
            String(localized: "Use a photo (JPEG, PNG, HEIC) or a PDF.", comment: "Receipt error")
        }
    }
}
