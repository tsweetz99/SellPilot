import XCTest
final class SellPilotUITests: XCTestCase {
    func testCreatePublishAndPersistItem() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString; app.launch()
        app.buttons["sellSomething"].tap()
        XCTAssertTrue(app.buttons["demoPhoto"].waitForExistence(timeout: 5)); app.buttons["demoPhoto"].tap()
        tap("Analyze photos", in: app)
        XCTAssertTrue(app.textFields["productTitle"].waitForExistence(timeout: 5))
        app.textFields["productTitle"].tap(); app.textFields["productTitle"].typeText(" UI test")
        tap("Confirm item", in: app); tap("Research my item", in: app); tap("Choose my price", in: app)
        tap("Find the best places", in: app); tap("Review photos", in: app); tap("Generate my listings", in: app)
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
    private func tap(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        for _ in 0..<30 { if button.exists && button.isHittable { button.tap(); return }; app.swipeUp() }
        XCTFail("Button unavailable: \(name)")
    }
}
