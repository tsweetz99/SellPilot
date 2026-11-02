import XCTest

/// Captures the App Store screenshots from the debug-only sample data (`--screenshot-demo`).
/// It needs the seller's demo photos, so it is skipped unless `SELLPILOT_DEMO_PHOTOS` is set (pass it to xcodebuild as
/// `TEST_RUNNER_SELLPILOT_DEMO_PHOTOS`). `SELLPILOT_SCREENSHOT_DIR` says where to write the PNGs; they are also attached to the test result.
final class ScreenshotUITests: XCTestCase {
    private var outputFolder: URL?

    func testCaptureAppStoreScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let photos = environment["SELLPILOT_DEMO_PHOTOS"], !photos.isEmpty else { throw XCTSkip("Set SELLPILOT_DEMO_PHOTOS to capture App Store screenshots.") }
        outputFolder = environment["SELLPILOT_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outputFolder { try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true) }

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--public-mode", "--screenshot-demo"]
        app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["SELLPILOT_DEMO_PHOTOS"] = photos
        app.launch()

        // Home, with the three sample items.
        let skates = app.staticTexts["Crazy Skates Glam Roller Skates, Teal Glitter"]
        XCTAssertTrue(skates.waitForExistence(timeout: 20))
        settle(); shot(app, "00-home")

        // The skates open on their last step (Ready); the back arrow walks through the earlier ones without running any analysis.
        // They are opened from My Stuff > Drafts, where no scrolling is needed to reach them.
        app.tabBars.buttons["My Stuff"].tap(); app.buttons["Drafts"].tap()
        XCTAssertTrue(skates.waitForExistence(timeout: 10)); skates.tap()
        XCTAssertTrue(app.staticTexts["Your Listing Is Ready"].waitForExistence(timeout: 10))
        settle(); shot(app, "04-ready")
        goBack(app); XCTAssertTrue(app.staticTexts["What should you ask?"].waitForExistence(timeout: 5))
        settle(); shot(app, "03-price")
        goBack(app); XCTAssertTrue(app.staticTexts["Is this right?"].waitForExistence(timeout: 5))
        settle(); shot(app, "02-confirm")
        goBack(app); XCTAssertTrue(app.staticTexts["What are you selling?"].waitForExistence(timeout: 5))
        settle(); shot(app, "01-photograph")
        app.buttons["Done"].tap()

        // The book, on the Confirm step with its ISBN filled in.
        let book = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sovereignty")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.staticTexts["Is this right?"].waitForExistence(timeout: 10))
        let isbn = app.textFields["isbnField"]
        for _ in 0..<8 where !(isbn.exists && isbn.isHittable) { scrollDown(app) }
        app.buttons["Look up"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Ryan Michler")).firstMatch.waitForExistence(timeout: 10))
        settle(); shot(app, "05-book")
        app.buttons["Done"].tap()

        // Settings: backup and privacy.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10)); app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        settle(); shot(app, "06-settings")
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "chevron.left")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No back arrow in the navigation bar")
        back.tap()
    }

    /// A gentle scroll, so a screen stops where the content looks right instead of a full page further on.
    private func scrollDown(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.2)) }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let outputFolder { try? screenshot.pngRepresentation.write(to: outputFolder.appendingPathComponent("\(name).png")) }
    }
}
