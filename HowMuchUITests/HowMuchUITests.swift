import XCTest

final class HowMuchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSampleDataSmoke() throws {
        let app = launchApp()

        #if os(macOS)
        // XCTest can launch the Mac app with a menu bar and no scene window.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "HowMuch window did not appear")
        // The first column is a real List. NavigationSplitView content
        // identifiers are often omitted from the macOS accessibility tree.
        if !waitForAny(["sidebar.navigation", "app.loaded", "activity.screen"], in: app, timeout: 10) {
            XCTFail("Main window did not become reachable. Hierarchy: \(app.debugDescription)")
            return
        }
        XCTAssertFalse(element("app.locked", in: app).exists, "UI testing launched into the locked-data gate")
        XCTAssertTrue(element("ledger.currency", in: app).waitForExistence(timeout: 5))
        if !waitForAny(["insights.range", "activity.screen"], in: app, timeout: 5) {
            XCTFail("Split content columns were not reachable. Hierarchy: \(app.debugDescription)")
            return
        }

        openMacSettings(in: app)
        XCTAssertTrue(element("settings.screen", in: app).waitForExistence(timeout: 5))
        let export = element("archive.export", in: app)
        let importArchive = element("archive.import", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(importArchive.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(importArchive.isEnabled)
        #else
        XCTAssertTrue(element("activity.screen", in: app).waitForExistence(timeout: 10))

        let settingsTab = app.tabBars.buttons["Settings"]
        if settingsTab.waitForExistence(timeout: 2) {
            app.tabBars.buttons["Insights"].tap()
            XCTAssertTrue(element("insights.range", in: app).waitForExistence(timeout: 5))

            app.tabBars.buttons["Ledgers"].tap()
            XCTAssertTrue(element("ledger.currency", in: app).waitForExistence(timeout: 5))
            settingsTab.tap()
        } else {
            let settingsButton = element("split.settings", in: app)
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
            settingsButton.tap()
        }
        XCTAssertTrue(element("settings.screen", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("archive.export", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("archive.import", in: app).waitForExistence(timeout: 5))
        #endif
    }

    #if os(iOS)
    @MainActor
    @available(iOS 17.0, *)
    func testActivityAccessibilityAudit() throws {
        let app = launchApp()
        XCTAssertTrue(element("activity.screen", in: app).waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [
            .elementDetection,
            .hitRegion,
            .sufficientElementDescription,
            .trait
        ]) { issue in
            // SwiftUI rows that publish one combined VoiceOver label still
            // draw child text. The audit reports that as inaccessible text
            // with no element, which is a false positive.
            issue.auditType == .elementDetection
                && issue.element == nil
                && issue.compactDescription.localizedCaseInsensitiveContains("inaccessible text")
        }
    }
    #endif

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitForAny(_ identifiers: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if identifiers.contains(where: { element($0, in: app).exists }) {
                return true
            }
        } while Date() < end && RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        return identifiers.contains(where: { element($0, in: app).exists })
    }

    #if os(macOS)
    @MainActor
    private func openMacSettings(in app: XCUIApplication) {
        app.activate()
        let applicationMenu = app.menuBars.menuBarItems["HowMuch"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 5))
        applicationMenu.click()

        var settingsItem = app.menuBars.menuItems["Settings…"]
        if !settingsItem.waitForExistence(timeout: 1) {
            settingsItem = app.menuBars.menuItems["Settings..."]
        }
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5))
        settingsItem.click()
    }
    #endif
}
