import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ReceiptDraft: Equatable {
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

    static func load(from url: URL) throws -> ReceiptDraft {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        return try make(data: data, fileName: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
    }

    static func make(data: Data, fileName: String, type: UTType?) throws -> ReceiptDraft {
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

    func previewFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HowMuchReceipts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(displayName)
        try data.write(to: url, options: .atomic)
        return url
    }

    #if os(iOS)
    typealias Thumbnail = UIImage
    #else
    typealias Thumbnail = NSImage
    #endif

    var thumbnail: Thumbnail? {
        #if os(iOS)
        UIImage(data: data)
        #else
        NSImage(data: data)
        #endif
    }

    private static func compressedImageData(from data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 2400
        let size = image.size
        let longest = max(size.width, size.height)
        let scaled = longest > maxDimension
            ? image.preparingThumbnail(of: CGSize(width: size.width * maxDimension / longest, height: size.height * maxDimension / longest)) ?? image
            : image
        return scaled.jpegData(compressionQuality: 0.8)
        #else
        guard let image = NSImage(data: data) else { return nil }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #endif
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
