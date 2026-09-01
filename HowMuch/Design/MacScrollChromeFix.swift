#if os(macOS)
import SwiftUI

extension View {
    /// Public-API fallback: permit the SwiftUI child to contract and let its
    /// native List/Form supply scrolling. SwiftUI does not expose hosting-view
    /// sizing options for views embedded by NavigationSplitView.
    func hmMacListFillsColumn() -> some View {
        frame(minHeight: 0, maxHeight: .infinity)
    }
}
#else
import SwiftUI

extension View {
    func hmMacListFillsColumn() -> some View { self }
}
#endif
