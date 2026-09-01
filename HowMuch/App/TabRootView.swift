import SwiftUI

struct TabRootView: View {
    var body: some View {
        TabView {
            Tab("Activity", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    ActivityView()
                }
            }
            Tab("Insights", systemImage: "chart.bar") {
                NavigationStack {
                    InsightsView()
                }
            }
            Tab("Ledgers", systemImage: "books.vertical") {
                NavigationStack {
                    LedgersView()
                }
            }
            Tab("Settings", systemImage: "gear") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
