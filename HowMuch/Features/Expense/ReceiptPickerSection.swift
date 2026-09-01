import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ReceiptPickerSection: View {
    @Binding var receipt: ReceiptDraft?
    @Binding var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    let isProcessing: Bool
    @State private var previewSelection = LatestSelectionToken()
    @State private var previewTask: Task<Void, Never>?
    #if os(iOS)
    @Binding var showingFileImporter: Bool
    @Binding var previewURL: URL?
    var onPickPhoto: () -> Void
    #else
    var onPickFile: () -> Void
    #endif
    var onRemoveReceipt: () -> Void

    var body: some View {
        Section {
            if let receipt {
                receiptPreview(receipt)
                sourceButtons
                Button(String(localized: "Remove Receipt", comment: "Button"), role: .destructive) {
                    onRemoveReceipt()
                }
            } else {
                sourceButtons
            }
            if isProcessing {
                HStack {
                    ProgressView()
                    Text(String(localized: "Preparing receipt…", comment: "Receipt progress"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("receipt.processing")
            }
        } header: {
            Text(String(localized: "Receipt", comment: "Form section"))
        } footer: {
            Text(String(localized: "Optional. Photos and PDFs, up to 10 MB."))
                .hmWrappingFooter()
        }
        .task {
            _ = await Task.detached(priority: .utility) {
                ReceiptPreviewFiles.removeStale()
            }.value
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            cancelPreview()
            #if os(iOS)
            let oldURL = previewURL
            previewURL = nil
            Task.detached(priority: .utility) {
                ReceiptPreviewFiles.cleanup(oldURL)
                ReceiptPreviewFiles.removeStale()
            }
            #else
            Task.detached(priority: .utility) {
                ReceiptPreviewFiles.removeStale()
            }
            #endif
        }
        .onChange(of: receipt) { _, _ in
            cancelPreview()
            #if os(iOS)
            previewURL = nil
            #endif
        }
        #if os(iOS)
        .onChange(of: previewURL) { oldURL, newURL in
            guard oldURL != newURL else { return }
            Task.detached(priority: .utility) {
                ReceiptPreviewFiles.cleanup(oldURL)
            }
        }
        .onDisappear {
            cancelPreview()
            let oldURL = previewURL
            previewURL = nil
            Task.detached(priority: .utility) {
                ReceiptPreviewFiles.cleanup(oldURL)
            }
        }
        #else
        .onDisappear {
            cancelPreview()
        }
        #endif
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
            openPreview(receipt)
        } label: {
            HStack(spacing: 12) {
                ReceiptThumbnailView(receipt: receipt)
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

    @MainActor
    private func openPreview(_ receipt: ReceiptDraft) {
        previewTask?.cancel()
        let token = previewSelection.begin()
        previewTask = Task {
            do {
                let url = try await receipt.previewFileURL()
                guard !Task.isCancelled, previewSelection.isCurrent(token) else {
                    await Task.detached(priority: .utility) {
                        ReceiptPreviewFiles.cleanup(url)
                    }.value
                    return
                }
                #if os(iOS)
                previewURL = url
                #else
                NSWorkspace.shared.open(url)
                try? await Task.sleep(for: .seconds(120))
                await Task.detached(priority: .utility) {
                    ReceiptPreviewFiles.cleanup(url)
                }.value
                #endif
            } catch is CancellationError {
                // A newer preview request owns the result.
            } catch {
                guard previewSelection.isCurrent(token) else { return }
                errorMessage = error.localizedDescription
            }
            guard previewSelection.isCurrent(token) else { return }
            previewTask = nil
        }
    }

    @MainActor
    private func cancelPreview() {
        previewSelection.invalidate()
        previewTask?.cancel()
        previewTask = nil
    }
}

private struct ReceiptThumbnailView: View {
    let receipt: ReceiptDraft
    @State private var thumbnailData: Data?
    @ScaledMetric(relativeTo: .body) private var size = 44

    var body: some View {
        Group {
            if !receipt.isPDF, let thumbnailData, let image = platformImage(thumbnailData) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: receipt.isPDF ? "doc.richtext" : "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: receipt.data) {
            thumbnailData = await receipt.thumbnailData()
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #endif
    }
}
