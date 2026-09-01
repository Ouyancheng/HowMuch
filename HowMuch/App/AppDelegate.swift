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
    private var uiTestingFallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PersistenceController.isUITesting {
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
            NSWindow.allowsAutomaticWindowTabbing = false
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                self.ensureVisibleMainWindow()
            }
        }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
            if PersistenceController.isUITesting {
                ensureVisibleMainWindow()
            }
        }
        return true
    }

    /// XCTest launches this SwiftUI app without restoring a WindowGroup scene,
    /// so UI tests see a menu bar and no window. Host the same root view when
    /// that happens.
    private func ensureVisibleMainWindow() {
        if NSApp.windows.contains(where: { $0.styleMask.contains(.titled) && $0.frame.width > 50 }) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let persistence = PersistenceController.shared
        let root = RootView()
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(AppState())
            .environment(CloudKitAccountMonitor())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HowMuch"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        MacWindowChrome.enableFullScreen(window)
        uiTestingFallbackWindow = window
        NSApp.activate(ignoringOtherApps: true)
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
