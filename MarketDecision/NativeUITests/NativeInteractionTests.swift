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
        XCTAssertEqual(input.label, "输入凭据")
        waitEnabled(input)
    }
    private var input: XCUIElement { app.secureTextFields["credentialInput"].firstMatch }
    private var save: XCUIElement { app.buttons["credentialSave"].firstMatch }
    private var delete: XCUIElement { app.buttons["credentialDelete"].firstMatch }
    private var mainWindow: XCUIElement {
        app.windows.containing(.button, identifier: "pageSettings").firstMatch
    }
    private func sheet(in window: XCUIElement) -> XCUIElement { window.sheets.firstMatch }
    private var windowInventory: String {
        app.windows.allElementsBoundByIndex.enumerated().map { index, window in
            "#\(index) id=\(window.identifier) title=\(window.title) credentialInput=\(window.secureTextFields["credentialInput"].exists) mainNavigation=\(window.buttons["pageSettings"].exists)"
        }.joined(separator: "\n")
    }
    private func independentSettingsWindow() -> XCUIElement {
        let candidates = app.windows.containing(.secureTextField, identifier: "credentialInput")
        guard candidates.element(boundBy: 1).waitForExistence(timeout: 10) else {
            XCTFail("Expected a second credential Settings window. Windows:\n\(windowInventory)")
            return candidates.element(boundBy: 1)
        }
        guard let independent = candidates.allElementsBoundByIndex.first(where: {
            !$0.buttons["pageSettings"].exists
        }) else {
            XCTFail("Could not distinguish independent Settings from the main window. Windows:\n\(windowInventory)")
            return candidates.element(boundBy: 1)
        }
        return independent
    }
    private func waitEnabled(_ element: XCUIElement, _ enabled: Bool = true) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func waitNoSheet(in window: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet(in: window))
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
        let main = mainWindow
        firstSave()
        delete.click()
        XCTAssertTrue(sheet(in: main).waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        waitNoSheet(in: main); waitEnabled(delete, false)
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
        launchSettings(); let main = mainWindow; firstSave()
        // Type without refocusing: successful save must return focus to this page's input.
        app.typeText("SYNTHETIC-UI-replacement")
        waitEnabled(save)
        app.typeKey("s", modifierFlags: .command)
        let replacement = sheet(in: main)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        XCTAssertTrue(replacement.staticTexts["替换本机凭据？"].exists)
        XCTAssertTrue(replacement.buttons["替换"].exists && replacement.buttons["取消"].exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(replacement.exists)
        app.typeKey(.escape, modifierFlags: [])
        waitNoSheet(in: main)
        app.typeText("-after-cancel")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet(in: main).waitForExistence(timeout: 5))
        app.typeKey("r", modifierFlags: .command)
        waitNoSheet(in: main); waitEnabled(save, false)
        delete.click()
        XCTAssertTrue(sheet(in: main).waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet(in: main).exists)
        app.typeKey("d", modifierFlags: .command)
        waitNoSheet(in: main); waitEnabled(delete, false)
        app.typeText("SYNTHETIC-UI-after-delete")
        waitEnabled(save)
    }
    func testIndependentSettingsSharesStateAndInvalidatesOldSheet() {
        launchSettings(); firstSave()
        let main = mainWindow
        app.typeKey(",", modifierFlags: .command)
        let independent = independentSettingsWindow()
        waitEnabled(independent.buttons["credentialDelete"])
        // Each page has its own draft/confirmation while sharing the credential model.
        main.buttons["pageSettings"].click()
        main.secureTextFields["credentialInput"].click()
        app.typeText("SYNTHETIC-UI-stale")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet(in: main).waitForExistence(timeout: 5))
        // The main window can fully cover Settings on a small runner display.
        // Raise the existing Settings scene before clicking its controls.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(sheet(in: main).exists) // Raising the other window must not consume confirmation.
        independent.buttons["credentialCheck"].click()
        waitNoSheet(in: main)
        // Check completion must retain the initiating window and restore its input.
        app.typeText("SYNTHETIC-UI-settings")
        waitEnabled(independent.buttons["credentialSave"])
        // Commands must come from the key Settings scene, not the other page.
        app.typeKey("l", modifierFlags: .command)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(sheet(in: independent).waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        waitNoSheet(in: independent)
    }
    func testFailedSaveRequiresCheckBeforeRetry() {
        launchSettings(failFirstSave: true)
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-failure")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(input, false)
        XCTAssertFalse(save.isEnabled); XCTAssertFalse(delete.isEnabled)
        let failureMessage = app.staticTexts["credentialMessage"].firstMatch
        XCTAssertTrue(failureMessage.waitForExistence(timeout: 5))
        XCTAssertEqual(failureMessage.label, "保存失败，未确认凭据是否已保存。请检查钥匙串状态后重试。")
        app.typeKey("r", modifierFlags: [.command, .shift])
        waitEnabled(input)
        // Check completion restores focus, and a fresh explicit save may retry.
        app.typeText("SYNTHETIC-UI-retry")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(delete)
    }
}
