import XCTest

/// Actual native events against shared production views, with a separate in-memory test app.
/// No Keychain, real provider, UI screenshots uploaded, or VoiceOver/IME acceptance implied.
@MainActor final class NativeInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private func configure() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "local.marketdecision.ui-test-host")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-appearance", "light"]
    }
    override func tearDown() async throws { app?.terminate(); app = nil }
    private func launchSettings(failFirstSave: Bool = false) {
        configure()
        if failFirstSave { app.launchArguments.append("--synthetic-fail-first-save") }
        app.launch()
        let settings = app.buttons["pageSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.click()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        waitEnabled(input)
    }
    private var input: XCUIElement { app.secureTextFields["credentialInput"].firstMatch }
    private var save: XCUIElement { app.buttons["credentialSave"].firstMatch }
    private var delete: XCUIElement { app.buttons["credentialDelete"].firstMatch }
    private var sheet: XCUIElement { app.sheets.firstMatch }
    private func waitEnabled(_ element: XCUIElement, _ enabled: Bool = true) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func waitNoSheet() {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func firstSave() {
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-first")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(delete)
        waitEnabled(save, false)
    }
    func testReturnDoesNotSaveAndTabSkipsDisabledControls() {
        launchSettings()
        firstSave()
        delete.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        waitNoSheet(); waitEnabled(delete, false)
        let message = app.staticTexts["credentialMessage"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(delete.isEnabled)
        app.typeKey("l", modifierFlags: .command)
        app.typeKey(.tab, modifierFlags: [])
        // A successful Check clears the deletion message. Merely leaving the input
        // enabled would not prove that Tab skipped the two disabled write controls.
        app.typeKey(.return, modifierFlags: [])
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        waitEnabled(input)
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-return")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(delete.isEnabled) // Return in the text field did not create a credential.
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(delete)
        waitEnabled(save, false)
    }
    func testNativeReplaceDeleteRequireExplicitKeysAndRestoreFocus() {
        launchSettings(); firstSave()
        // Type without refocusing: successful save must return focus to this page's input.
        app.typeText("SYNTHETIC-UI-replacement")
        waitEnabled(save)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.exists)
        app.typeKey(.escape, modifierFlags: [])
        waitNoSheet()
        app.typeText("-after-cancel")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: .command)
        waitNoSheet(); waitEnabled(save, false)
        delete.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.exists)
        app.typeKey("d", modifierFlags: .command)
        waitNoSheet(); waitEnabled(delete, false)
        app.typeText("SYNTHETIC-UI-after-delete")
        waitEnabled(save)
    }
    func testIndependentSettingsSharesStateAndInvalidatesOldSheet() {
        launchSettings(); firstSave()
        let main = app.windows.containing(.button, identifier: "pageSettings").firstMatch
        app.typeKey(",", modifierFlags: .command)
        let independent = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(independent.waitForExistence(timeout: 10))
        waitEnabled(independent.buttons["credentialDelete"])
        // Each page has its own draft/confirmation while sharing the credential model.
        main.buttons["pageSettings"].click()
        main.secureTextFields["credentialInput"].click()
        app.typeText("SYNTHETIC-UI-stale")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        // The main window can fully cover Settings on a small runner display.
        // Raise the existing Settings scene before clicking its controls.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(sheet.exists) // Raising the other window must not consume confirmation.
        independent.buttons["credentialCheck"].click()
        waitNoSheet()
        // Commands must come from the key Settings scene, not the other page.
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-settings")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(independent.sheets.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        waitNoSheet()
    }
    func testFailedSaveRequiresCheckBeforeRetry() {
        launchSettings(failFirstSave: true)
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-failure")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(input, false)
        XCTAssertFalse(save.isEnabled); XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(app.staticTexts["credentialMessage"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: [.command, .shift])
        waitEnabled(input)
        // Check completion restores focus, and a fresh explicit save may retry.
        app.typeText("SYNTHETIC-UI-retry")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(delete)
    }
}
