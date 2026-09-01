import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ReceiptPickerSection: View {
    @Binding var receipt: ReceiptDraft?
    @Binding var errorMessage: String?
    #if os(iOS)
    @Binding var showingFileImporter: Bool
    @Binding var previewURL: URL?
    var onPickPhoto: () -> Void
    #else
    var onPickFile: () -> Void
    #endif

    var body: some View {
        Section {
            if let receipt {
                receiptPreview(receipt)
                sourceButtons
                Button(String(localized: "Remove Receipt", comment: "Button"), role: .destructive) {
                    self.receipt = nil
                    #if os(iOS)
                    previewURL = nil
                    #endif
                }
            } else {
                sourceButtons
            }
        } header: {
            Text("Receipt")
        } footer: {
            Text("Optional. Photos and PDFs, up to 10 MB.")
                .hmWrappingFooter()
        }
    }

    @ViewBuilder
    private var sourceButtons: some View {
        #if os(iOS)
        Button(action: onPickPhoto) {
            Label(
                receipt == nil
                    ? String(localized: "Add Photo", comment: "Button")
                    : String(localized: "Replace Photo", comment: "Button"),
                systemImage: "photo"
            )
        }
        Button {
            showingFileImporter = true
        } label: {
            Label(
                receipt == nil
                    ? String(localized: "Add PDF or File", comment: "Button")
                    : String(localized: "Replace with File", comment: "Button"),
                systemImage: "doc"
            )
        }
        #else
        Button(
            receipt == nil
                ? String(localized: "Add Photo or PDF", comment: "Button")
                : String(localized: "Replace Receipt", comment: "Button"),
            action: onPickFile
        )
        #endif
    }

    @ViewBuilder
    private func receiptPreview(_ receipt: ReceiptDraft) -> some View {
        Button {
            do {
                let url = try receipt.previewFileURL()
                #if os(iOS)
                previewURL = url
                #else
                NSWorkspace.shared.open(url)
                #endif
            } catch {
                errorMessage = error.localizedDescription
            }
        } label: {
            HStack(spacing: 12) {
                receiptThumbnail(receipt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.displayName)
                        .foregroundStyle(.primary)
                    Text(receipt.isPDF
                         ? String(localized: "PDF", comment: "Receipt kind")
                         : String(localized: "Photo", comment: "Receipt kind"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "View receipt", comment: "Button"))
    }

    @ViewBuilder
    private func receiptThumbnail(_ receipt: ReceiptDraft) -> some View {
        if !receipt.isPDF, let thumbnail = receipt.thumbnail {
            platformImage(thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: receipt.isPDF ? "doc.richtext" : "photo")
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(.secondary)
        }
    }

    private func platformImage(_ thumbnail: ReceiptDraft.Thumbnail) -> Image {
        #if os(iOS)
        Image(uiImage: thumbnail)
        #else
        Image(nsImage: thumbnail)
        #endif
    }
}
