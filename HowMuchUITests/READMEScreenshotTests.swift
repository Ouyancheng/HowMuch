import XCTest

final class READMEScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureREADMEScreenshots() throws {
        let app = launchApp()
        let prefix = screenshotPrefix()

        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAny(["sidebar.navigation", "app.loaded", "activity.screen"], in: app, timeout: 10))
        settle()
        write(screenshot(of: app.windows.firstMatch), name: "\(prefix)-main")

        let expense = firstExpense(in: app)
        if expense.waitForExistence(timeout: 5) {
            expense.click()
            let editor = app.windows.element(boundBy: 1)
            if editor.waitForExistence(timeout: 5) {
                settle()
                write(screenshot(of: editor), name: "\(prefix)-expense")
                app.typeKey("w", modifierFlags: .command)
            }
        }
        #else
        if app.tabBars.buttons["Activity"].waitForExistence(timeout: 2) {
            XCTAssertTrue(element("activity.screen", in: app).waitForExistence(timeout: 10))
            settle()
            write(screenshot(of: app), name: "\(prefix)-activity")

            app.tabBars.buttons["Insights"].tap()
            XCTAssertTrue(element("insights.range", in: app).waitForExistence(timeout: 5))
            settle()
            write(screenshot(of: app), name: "\(prefix)-insights")

            app.tabBars.buttons["Ledgers"].tap()
            XCTAssertTrue(waitForAny(["ledger.currency", "ledger.reporting-currency"], in: app, timeout: 5))
            settle()
            write(screenshot(of: app), name: "\(prefix)-ledgers")

            app.tabBars.buttons["Activity"].tap()
            XCTAssertTrue(element("activity.screen", in: app).waitForExistence(timeout: 5))
            let expense = firstExpense(in: app)
            XCTAssertTrue(expense.waitForExistence(timeout: 5))
            expense.tap()
            settle()
            write(screenshot(of: app), name: "\(prefix)-expense")
        } else {
            XCTAssertTrue(waitForAny(["sidebar.navigation", "activity.screen", "app.loaded"], in: app, timeout: 10))
            settle()
            write(screenshot(of: app), name: "\(prefix)-split")
        }
        #endif
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-screenshots",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        app.activate()
        return app
    }

    @MainActor
    private func screenshotPrefix() -> String {
        #if os(macOS)
        return "macos"
        #else
        let idiom = UIDevice.current.userInterfaceIdiom
        return idiom == .pad ? "ipad" : "iphone"
        #endif
    }

    @MainActor
    private func screenshot(of element: XCUIElement) -> XCUIScreenshot {
        element.screenshot()
    }

    @MainActor
    private func firstExpense(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Din Tai Fung")
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func write(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
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
}
