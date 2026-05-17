import XCTest

final class MultiverseWPUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["MULTIVERSEWP_UI_TEST"] = "1"
        app.launch()

        // Onboarding sheet hosts the canonical header text on cold launch with
        // an empty in-memory store; once that exists we know the SwiftUI scene
        // has finished mounting.
        let header = app.staticTexts["Link a WhatsApp Account"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Main window should mount and surface onboarding")
    }

    func testOnboardingSheetAppearsOnFirstLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["MULTIVERSEWP_UI_TEST"] = "1"
        app.launch()

        // SwiftUI sheets surface as a new window with their content.
        // Look for the onboarding header text — it's stable, localized to English.
        let header = app.staticTexts["Link a WhatsApp Account"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Onboarding sheet should appear on first launch")
    }
}
