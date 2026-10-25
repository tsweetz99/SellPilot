import XCTest
final class SellPilotUITests: XCTestCase {
    func testCreatePublishAndPersistItem() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString; app.launch()
        app.buttons["sellSomething"].tap()
        XCTAssertTrue(app.buttons["demoPhoto"].waitForExistence(timeout: 5)); app.buttons["demoPhoto"].tap()
        tap("Analyze photos", in: app)
        XCTAssertTrue(app.textFields["productTitle"].waitForExistence(timeout: 5))
        app.textFields["productTitle"].tap(); app.textFields["productTitle"].typeText(" UI test")
        tap("See pricing", in: app); tap("Generate my listings", in: app)
        let ready = XCTAttachment(screenshot: app.screenshot()); ready.name = "Listing ready"; ready.lifetime = .keepAlways; add(ready)
        tap("markActive", in: app); app.buttons["Confirm published"].tap()
        app.terminate(); app.launch(); XCTAssertTrue(app.staticTexts["Active"].exists)
        let item = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI test")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        tap("Mark Sold", in: app)
        let price = app.alerts.textFields.firstMatch; XCTAssertTrue(price.waitForExistence(timeout: 5)); price.tap()
        let old = price.value as? String ?? ""
        price.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "91")
        app.alerts.buttons["Save sale"].tap()
        app.terminate(); app.launch(); XCTAssertTrue(app.staticTexts["Sold"].exists); XCTAssertFalse(app.staticTexts["Active"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Home after sale and relaunch"; home.lifetime = .keepAlways; add(home)
    }
    func testHomeTilesOpenTheMatchingList() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString; app.launch()
        let drafts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tile-Drafts")).firstMatch
        XCTAssertTrue(drafts.waitForExistence(timeout: 5)); drafts.tap()
        XCTAssertTrue(app.staticTexts["No drafts yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Drafts"].isSelected)
        app.tabBars.buttons["Home"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tile-Sold")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No sold yet"].waitForExistence(timeout: 5))
    }
    /// Regression: refreshing prices from the Ready screen used to crash (the listing picker read a listing that had just been cleared).
    func testRefreshingPricesFromTheReadyScreenDoesNotCrash() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString; app.launch()
        app.buttons["sellSomething"].tap()
        XCTAssertTrue(app.buttons["demoPhoto"].waitForExistence(timeout: 5)); app.buttons["demoPhoto"].tap()
        tap("Analyze photos", in: app)
        XCTAssertTrue(app.textFields["productTitle"].waitForExistence(timeout: 5))
        tap("See pricing", in: app); tap("Generate my listings", in: app)
        tap("Refresh market prices", in: app)
        XCTAssertTrue(app.navigationBars["Price & places"].waitForExistence(timeout: 10), "the app should show Price & places after refreshing")
        let price = app.textFields["Asking price"]
        XCTAssertTrue(price.waitForExistence(timeout: 5)); price.tap(); price.typeText("1")
        tap("Generate my listings", in: app)
        XCTAssertTrue(app.navigationBars["Ready"].waitForExistence(timeout: 10))
    }
    /// The public app shows simple eBay settings; the developer fields (keys, sandbox, redirect name) are not there.
    func testPublicSettingsHideTheDeveloperFields() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--public-mode"]; app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString; app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5)); app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        func reveal(_ element: XCUIElement) -> Bool { for _ in 0..<12 { if element.exists && element.isHittable { return true }; app.swipeUp() }; return element.exists }
        XCTAssertTrue(reveal(app.textFields["Ship-from ZIP code"]), "the ZIP code field is there")
        XCTAssertTrue(app.switches["Publish to eBay"].exists, "the publish switch is there")
        XCTAssertTrue(app.staticTexts["eBay"].exists || app.staticTexts["EBAY"].exists, "an eBay section")
        for developerOnly in ["eBay App ID", "eBay Cert ID", "Sandbox App ID", "Sandbox user token", "Anthropic API key (optional)", "Production redirect name (RuName)", "Token server URL (optional)"] {
            XCTAssertFalse(app.secureTextFields[developerOnly].exists || app.textFields[developerOnly].exists, "\(developerOnly) should not show in the public app")
        }
        XCTAssertFalse(app.switches["Publish to real eBay"].exists)
    }

    private func tap(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        for _ in 0..<30 { if button.exists && button.isHittable { button.tap(); return }; app.swipeUp() }
        XCTFail("Button unavailable: \(name)")
    }
}
