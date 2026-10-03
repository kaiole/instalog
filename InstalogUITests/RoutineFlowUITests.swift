import XCTest

/// Drives the core loop through accessibility elements only (no swipes), covering AT-35.
/// Set SCREENSHOT_DIR to also write PNGs to disk.
@MainActor
final class RoutineFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-data"]
        app.launch()
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func loadDemo() {
        let demo = app.buttons["Load demo routine"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        XCTAssertTrue(logButton.label.hasPrefix("Log to Breakfast"))
    }

    private var logButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log '")).firstMatch
    }

    func testEmptyStateThenRoutineLogging() {
        snapshot("01-empty")
        loadDemo()
        snapshot("02-start-of-day")

        // Adjust one quantity for this log only.
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More '")).firstMatch
        XCTAssertTrue(more.exists)
        more.tap()
        XCTAssertTrue(app.buttons["Reset"].waitForExistence(timeout: 3))
        snapshot("03-adjusted")

        logButton.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        snapshot("04-logged")
        XCTAssertFalse(app.buttons["Reset"].exists, "Draft returns to saved defaults after logging")
        XCTAssertTrue(logButton.label.hasPrefix("Log again to Breakfast"))

        // Select another meal by its chip and log it too.
        app.buttons["Greek yogurt bowl"].tap()
        logButton.tap()
        // Logged entries are shown expanded by default.
        let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2 logged here'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        snapshot("05-entries-expanded")

        // Open an entry and delete it, then Undo.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Greek yogurt bowl, logged'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        snapshot("06-entry-sheet")
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2 logged here'")).firstMatch.waitForExistence(timeout: 5))

        // Browse sections with the buttons; wraps from first to last.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Previous section'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dinner, section 4'")).firstMatch.waitForExistence(timeout: 3))
        snapshot("07-dinner-all-meals")

        // Sections sheet.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dinner, section'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Here now"].waitForExistence(timeout: 3))
        snapshot("08-sections-sheet")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breakfast. 2 logged'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Breakfast, section 1'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testAddFoodSearchAndCustomPortion() {
        loadDemo()
        app.buttons["Add food"].tap()
        XCTAssertTrue(app.staticTexts["Add food"].waitForExistence(timeout: 3))
        snapshot("09-add-food")
        let search = app.textFields["Search foods and saved meals"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("banana")
        let banana = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Bananas, raw'")).firstMatch
        XCTAssertTrue(banana.waitForExistence(timeout: 5))
        snapshot("10-search")
        banana.tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add to Breakfast'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        snapshot("11-food-detail")
        add.tap()
        let logTo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Log to Breakfast'")).firstMatch
        XCTAssertTrue(logTo.waitForExistence(timeout: 3))
        snapshot("12-plate")
        logTo.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Added Bananas, raw to Breakfast'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("13-added")
    }

    func testSettingsAndNutrients() {
        loadDemo()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Auto-advance after logging"].waitForExistence(timeout: 3))
        snapshot("14-settings")
        app.buttons["Order sections and assign meals"].tap()
        XCTAssertTrue(app.navigationBars["Sections & meals"].waitForExistence(timeout: 3))
        snapshot("15-setup")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lunch'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Opens first"].waitForExistence(timeout: 3))
        snapshot("15b-section-meals")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Saved meals'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Overnight oats'")).firstMatch.tap()
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More '")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        snapshot("15c-meal-editor")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Saved meals"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Close"].firstMatch.tap()

        logButton.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Consumed'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Nutrients"].waitForExistence(timeout: 3))
        snapshot("16-nutrients")
    }

    private var firstAmountField: XCUIElement {
        app.textFields.matching(NSPredicate(format: "label CONTAINS ', amount in '")).firstMatch
    }

    /// Regression: −/+ while the amount field is focused must update the field, survive leaving
    /// the field, and tapping the field must select its value so typing replaces it.
    func testAmountFieldStaysInSyncWithSteppers() {
        loadDemo()
        let field = firstAmountField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let foodName = field.label.components(separatedBy: ", amount in ")[0]

        field.tap()
        field.typeText("150")
        XCTAssertEqual(field.value as? String, "150", "Tapping selects the old value, so typing replaces it")

        app.buttons["More \(foodName)"].tap()
        let stepped = field.value as? String
        XCTAssertNotEqual(stepped, "150", "+ updates the field while it has focus")

        app.buttons["Done"].tap()
        XCTAssertEqual(field.value as? String, stepped, "Leaving the field keeps the stepped value")
        XCTAssertTrue(app.buttons["Reset"].exists)
    }

    /// Regression: a typed amount counts even if Log is tapped before the keyboard is dismissed.
    func testTypedAmountIsLoggedWithoutDismissingKeyboard() {
        loadDemo()
        let field = firstAmountField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let foodName = field.label.components(separatedBy: ", amount in ")[0]
        field.tap()
        field.typeText("150")
        logButton.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))

        let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 logged here'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS ', logged'")).firstMatch.tap()
        // The main screen's field (reset to the default after logging) stays in the tree under the
        // sheet, so look for the logged amount among every field for this food.
        let fields = app.textFields.matching(NSPredicate(format: "label BEGINSWITH %@", "\(foodName), amount in "))
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3) || fields.count > 1)
        let values = fields.allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertTrue(values.contains("150"), "Logged amounts: \(values)")
    }
}
