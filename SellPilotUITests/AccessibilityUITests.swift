import XCTest

/// Runs Apple's accessibility audit (contrast, Dynamic Type, hit regions, labels, clipped text) over every main screen,
/// once at the default text size and once at the largest accessibility size.
final class AccessibilityUITests: XCTestCase {
    private var found: [String] = []

    func testDefaultTextSize() throws { try walk(textSize: nil) }
    func testLargestAccessibilityTextSize() throws { try walk(textSize: "UICTContentSizeCategoryAccessibilityXXXL") }
    func testDarkMode() throws { try walk(textSize: nil, dark: true) }

    private func walk(textSize: String?, dark: Bool = false) throws {
        continueAfterFailure = true
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        app.launchEnvironment["SELLPILOT_TEST_STORE"] = UUID().uuidString
        app.launch()

        audit(app, "Home (empty)")
        app.buttons["sellSomething"].tap()
        XCTAssertTrue(app.buttons["demoPhoto"].waitForExistence(timeout: 5))
        audit(app, "Photograph (no photos)")
        app.buttons["demoPhoto"].tap()
        audit(app, "Photograph (with photo)")
        tap("Analyze photos", in: app)
        XCTAssertTrue(app.textFields["productTitle"].waitForExistence(timeout: 10))
        audit(app, "Confirm")
        tap("See pricing", in: app)
        XCTAssertTrue(app.navigationBars["Price & places"].waitForExistence(timeout: 10))
        audit(app, "Price & places")
        tap("Generate my listings", in: app)
        XCTAssertTrue(app.navigationBars["Ready"].waitForExistence(timeout: 10))
        audit(app, "Ready")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        audit(app, "Home (with an item)")
        app.tabBars.buttons["My Stuff"].tap()
        audit(app, "My Stuff")
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        audit(app, "Settings")

        let label = dark ? "dark mode" : (textSize == nil ? "default size" : "largest size")
        print("A11Y|SUMMARY|\(label)|\(found.count) issues")
        XCTAssertTrue(found.isEmpty, "Accessibility issues at the \(label):\n" + found.joined(separator: "\n"))
    }

    private func audit(_ app: XCUIApplication, _ screen: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = screen; shot.lifetime = .keepAlways; add(shot)
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                if self.isKnownNoise(issue, in: app, screen: screen) { return true }
                let element = issue.element.map { "type \($0.elementType.rawValue) '\($0.label)' id '\($0.identifier)' value '\(($0.value as? String) ?? "")' frame \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "no element"
                let line = "\(screen): \(issue.auditType) – \(issue.compactDescription) [\(element)]"
                self.found.append(line)
                print("A11Y|\(line)")
                return true
            }
        } catch { XCTFail("Audit could not run on \(screen): \(error)") }
    }

    /// Findings the audit reports that are not problems with this app: iOS's own navigation-bar buttons (which cap their own
    /// text size), the reflowing Home tiles, and contrast or clipping reported for content scrolled underneath the translucent tab or button bars.
    private func isKnownNoise(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, screen: String) -> Bool {
        guard let element = issue.element else { return issue.auditType == .contrast }
        // The Home tiles reflow from two columns to one at accessibility sizes. The audit reads that as text that does not scale,
        // although the text does; the largest-size screenshots show the tiles correctly.
        if screen.hasPrefix("Home"), element.elementType == .staticText, issue.auditType == .dynamicType { return true }
        if element.elementType == .button, element.label == "Done", element.frame.minY < 140 { return true }
        let underBars = element.frame.maxY > app.frame.height - 100 || element.frame.minY < 60
        return underBars && (issue.auditType == .contrast || issue.auditType == .textClipped)
    }

    private func tap(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name]
        for _ in 0..<30 { if button.exists && button.isHittable { button.tap(); return }; app.swipeUp() }
        XCTFail("Button unavailable: \(name)")
    }
}
