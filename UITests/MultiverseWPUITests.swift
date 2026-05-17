import XCTest

final class MultiverseWPUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment["MULTIVERSEWP_UI_TEST"] = "1"
        app.launch()

        let sidebar = app.outlines["AccountSidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    }

    func testOnboardingSheetAppearsOnFirstLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["MULTIVERSEWP_UI_TEST"] = "1"
        app.launch()

        let onboarding = app.otherElements["AccountOnboardingView"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 5))
    }
}
