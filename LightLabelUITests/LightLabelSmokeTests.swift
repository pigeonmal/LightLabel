import XCTest

final class LightLabelSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsOfflineWelcomeAndPrimaryActions() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["LightLabel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["welcome.privacy"].exists)
        XCTAssertTrue(app.buttons["welcome.createDataset"].exists)
        XCTAssertTrue(app.buttons["welcome.openDataset"].exists)
    }
}
