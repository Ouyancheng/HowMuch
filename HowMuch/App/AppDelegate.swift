import CloudKit
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

#if os(iOS)
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PersistenceController.shared.acceptShare(metadata: cloudKitShareMetadata)
    }
}
#endif

#if os(macOS)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacWindowChrome.enableFullScreenOnOpenWindows()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MacWindowChrome.enableFullScreenOnOpenWindows()
            }
        }
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        PersistenceController.shared.acceptShare(metadata: cloudKitShareMetadata)
    }
}

@MainActor
enum MacWindowChrome {
    static func enableFullScreenOnOpenWindows() {
        NSApp.windows.forEach(enableFullScreen)
    }

    static func enableFullScreen(_ window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenAllowsTiling)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.miniaturizable)
    }
}
#endif
