import Combine
import CoreData
import SwiftUI

@main
struct HowMuchApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var persistence = PersistenceController.shared
    @State private var appState = AppState()
    @State private var accountMonitor = CloudKitAccountMonitor()

    var body: some Scene {
        WindowGroup(id: "howmuch.main.v5") {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(persistence)
                .environment(appState)
                .environment(accountMonitor)
                .task(id: accountMonitor.generation) {
                    await persistence.applyAccountIdentity(accountMonitor.identity)
                }
                .onChange(of: persistence.stackGeneration, initial: true) { _, generation in
                    appState.resetForStackGeneration(generation)
                }
                .onOpenURL { url in
                    let generation = appState.beginOpeningArchive()
                    let accessed = url.startAccessingSecurityScopedResource()
                    Task {
                        do {
                            let package = try await Task.detached(priority: .userInitiated) {
                                defer {
                                    if accessed {
                                        url.stopAccessingSecurityScopedResource()
                                    }
                                }
                                return try HowMuchArchiveDocument.loadPackage(from: url)
                            }.value
                            appState.finishOpeningArchive(package, generation: generation)
                        } catch {
                            appState.failOpeningArchive(error, generation: generation)
                        }
                    }
                }
                #if os(macOS)
                .windowFullScreenBehavior(.enabled)
                .windowResizeBehavior(.enabled)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 920, height: 560)
        .windowResizability(.automatic)
        .windowIdealSize(.automatic)
        .commands {
            HowMuchCommands()
        }
        #endif

        #if os(macOS)
        WindowGroup(id: HowMuchWindowID.newExpense) {
            DataAvailabilityGate {
                MacEditorContainer {
                    ExpenseEditorView(expense: nil)
                }
            }
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(appState)
            .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 480, height: 460)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)

        WindowGroup(id: HowMuchWindowID.editExpense, for: UUID.self) { $expenseID in
            DataAvailabilityGate {
                MacEditorContainer {
                    ExpenseWindowHost(expenseID: expenseID)
                }
            }
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(appState)
            .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 480, height: 460)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)

        WindowGroup(id: HowMuchWindowID.ledgerSettings, for: UUID.self) { $ledgerID in
            DataAvailabilityGate {
                MacEditorContainer {
                    LedgerSettingsWindowHost(ledgerID: ledgerID)
                }
            }
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
            .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 440, height: 400)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)

        WindowGroup(id: HowMuchWindowID.newPersonal) {
            DataAvailabilityGate {
                MacEditorContainer {
                    NewLedgerView(kind: .personal)
                }
            }
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
            .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 420, height: 280)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)

        WindowGroup(id: HowMuchWindowID.newHousehold) {
            DataAvailabilityGate {
                MacEditorContainer {
                    NewLedgerView(kind: .household)
                }
            }
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(appState)
            .environment(accountMonitor)
            .windowFullScreenBehavior(.enabled)
        }
        .defaultSize(width: 420, height: 280)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .environmentObject(persistence)
                .environment(appState)
                .environment(accountMonitor)
        }
        #endif
    }
}

#if os(macOS)
struct HowMuchCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.selectedLedgerIsWritable) private var selectedLedgerIsWritable

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Expense", comment: "Menu item")) {
                openWindow(id: HowMuchWindowID.newExpense)
            }
            .keyboardShortcut("n")
            .disabled(selectedLedgerIsWritable != true)
            Button(String(localized: "New Personal Ledger", comment: "Menu item")) {
                openWindow(id: HowMuchWindowID.newPersonal)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(String(localized: "New Family Ledger", comment: "Menu item")) {
                openWindow(id: HowMuchWindowID.newHousehold)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
#endif
