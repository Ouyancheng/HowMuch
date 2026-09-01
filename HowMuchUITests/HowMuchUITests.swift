import XCTest

final class HowMuchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSampleDataSmoke() throws {
        let app = launchApp()
        XCTAssertTrue(element("activity.screen", in: app).waitForExistence(timeout: 10))

        #if os(macOS)
        app.activate()
        XCTAssertTrue(element("insights.range", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("ledger.currency", in: app).waitForExistence(timeout: 5))

        openMacSettings(in: app)
        XCTAssertTrue(element("settings.screen", in: app).waitForExistence(timeout: 5))
        let export = element("archive.export", in: app)
        let importArchive = element("archive.import", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(importArchive.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(importArchive.isEnabled)
        #else
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
        ])
    }
    #endif

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
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
