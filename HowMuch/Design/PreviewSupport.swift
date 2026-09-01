import SwiftUI

#if DEBUG
enum HowMuchPreview {
    @MainActor
    static var persistence: PersistenceController { .preview }

    @MainActor
    static func wrap<Content: View>(_ content: Content) -> some View {
        content
            .environment(\.managedObjectContext, persistence.viewContext)
            .environmentObject(persistence)
            .environment(AppState())
            .environment(CloudKitAccountMonitor())
    }
}
#endif
