import CloudKit
import SwiftUI

#if os(iOS)
import UIKit

struct CloudShareSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onEnd: () -> Void = {}

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnd: onEnd)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onEnd: () -> Void
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onEnd()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onEnd()
        }
    }
}
#endif

#if os(macOS)
import AppKit
import CoreData

struct MacCloudShareTrigger: NSViewRepresentable {
    var share: CKShare?
    var container: CKContainer?
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityHidden(true)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, let share, let container else { return }
        DispatchQueue.main.async {
            isPresented = false
            MacCloudSharing.present(share: share, container: container, from: nsView)
        }
    }
}

@MainActor
enum MacCloudSharing {
    static func present(share: CKShare, container: CKContainer, from view: NSView?) {
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        let picker = NSSharingServicePicker(items: [itemProvider])
        let anchor = view ?? NSApp.keyWindow?.contentView
        guard let anchor else { return }
        let rect = anchor.bounds
        picker.show(relativeTo: NSRect(x: rect.midX, y: rect.midY, width: 1, height: 1), of: anchor, preferredEdge: .minY)
    }
}
#endif
