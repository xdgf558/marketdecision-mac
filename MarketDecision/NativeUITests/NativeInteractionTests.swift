import XCTest

/// Actual native events against shared production views, with a separate synthetic test app.
/// The SEC-open failure case uses disposable host-local files; other fixtures stay in memory.
/// No Keychain, real provider, UI screenshots uploaded, or VoiceOver/IME acceptance implied.
@MainActor final class NativeInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private func configure() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "local.marketdecision.ui-test-host")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-appearance", "light"]
    }
    override func tearDown() async throws { app?.terminate(); app = nil }
    private func launchMainWindow() {
        app.launch()
        app.activate()
        if !mainWindow.waitForExistence(timeout: 15) {
            // A launch may restore the test app with menus but no WindowGroup
            // window. Use its observed standard File command, never preferences
            // resets, a production launch hook, or a skipped business assertion.
            let existingWindow = app.windows.matching(NSPredicate(format: "title == %@", "MarketDecision")).firstMatch
            guard !existingWindow.exists else {
                XCTFail("A MarketDecision window exists without its main navigation. App hierarchy:\n\(app.debugDescription)")
                return
            }
            let fileMenu = app.menuBars.menuBarItems["文件"].firstMatch
            guard fileMenu.waitForExistence(timeout: 5), fileMenu.isEnabled else {
                XCTFail("No main window or enabled File menu after launch. App hierarchy:\n\(app.debugDescription)")
                return
            }
            fileMenu.click()
            let newWindow = fileMenu.menuItems["新MarketDecision窗口"].firstMatch
            guard newWindow.waitForExistence(timeout: 5), newWindow.isEnabled else {
                XCTFail("The observed New MarketDecision Window command is unavailable. App hierarchy:\n\(app.debugDescription)")
                return
            }
            newWindow.click()
            app.activate()
        }
        guard mainWindow.waitForExistence(timeout: 15) else {
            XCTFail("The main window did not appear after explicit creation. App hierarchy:\n\(app.debugDescription)")
            return
        }
        let navigation = mainWindow.buttons["pageSettings"]
        let ready = NSPredicate { _, _ in
            navigation.exists && navigation.isEnabled && navigation.isHittable
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: navigation)], timeout: 10)
        XCTAssertEqual(result, .completed, "Main navigation is not interactable. App hierarchy:\n\(app.debugDescription)")
    }
    private func launchSettings(failFirstSave: Bool = false) {
        configure()
        if failFirstSave { app.launchArguments.append("--synthetic-fail-first-save") }
        launchMainWindow()
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
    private var credentialMessage: XCUIElement {
        app.descendants(matching: .any)["credentialMessage"].firstMatch
    }
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
    private func clickCredentialButton(_ identifier: String, in window: XCUIElement) {
        let button = window.buttons[identifier].firstMatch
        // Form exposes credential controls in AX even when its viewport clips
        // them. An enabled button alone is not evidence that a mouse click can
        // reach it, especially after status text changes the form's height.
        let containingForm = window.scrollViews.containing(.button, identifier: identifier).firstMatch
        // The Settings page has one Form; use it before a lazy target appears.
        let form = containingForm.exists ? containingForm : window.scrollViews.firstMatch
        guard form.waitForExistence(timeout: 5) else {
            XCTFail("Missing credential Form: \(window.debugDescription)")
            return
        }
        func visibleViewport() -> CGRect {
            form.frame.intersection(window.frame).insetBy(dx: 0, dy: 4)
        }
        func fullyVisible() -> Bool {
            guard button.exists else { return false }
            let viewport = visibleViewport()
            return !viewport.isEmpty && !button.frame.isEmpty &&
                viewport.contains(button.frame) && button.isHittable
        }
        for _ in 0..<24 {
            if fullyVisible() { break }
            // Use the actual form, not the application or another Settings
            // window. Scroll in bounded steps, including lazy AX materialization.
            let distance = button.exists ? visibleViewport().midY - button.frame.midY : -100
            form.scroll(byDeltaX: 0, deltaY: max(-160, min(160, distance)))
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing credential action: \(window.debugDescription)")
        waitEnabled(button)
        guard fullyVisible() else {
            XCTFail("Credential action must be fully inside its Form before clicking: button=\(button.frame), form=\(form.frame), window=\(window.frame)\n\(window.debugDescription)")
            return
        }
        button.click()
    }
    private func firstSave() {
        app.typeKey("l", modifierFlags: .command)
        app.typeText("SYNTHETIC-UI-first")
        app.typeKey("s", modifierFlags: .command)
        waitEnabled(delete)
        waitEnabled(save, false)
    }
    private func researchTab(_ title: String) {
        let surface = mainWindow
        if mainWindow.buttons["optionLabInputTab"].exists {
            let daily = ["输入": "optionLabInputTab", "结果": "optionLabResultTab", "已保存": "optionLabSavedTab"]
            if let id = daily[title] {
                let button = mainWindow.buttons[id]
                XCTAssertTrue(button.waitForExistence(timeout: 5)); waitEnabled(button)
                revealOptionControl(button); button.click()
                return
            }
            if ["数据对照", "组合风险", "期权链", "模型分析", "风险与情景", "波动率历史", "期权归档"].contains(title) {
                let button = mainWindow.buttons["optionLabAdvanced-" + title]
                expandDisclosure("optionLabAdvancedTools", revealing: button)
                XCTAssertTrue(button.waitForExistence(timeout: 5)); waitEnabled(button)
                revealOptionControl(button); button.click()
                return
            }
        }
        // macOS exposes SwiftUI segmented pickers as radio groups on some
        // deployment targets. Keep the query in this app's main window,
        // without assuming the iOS-style SegmentedControl container type.
        let radio = surface.radioButtons[title]
        if radio.exists {
            waitEnabled(radio); revealOptionControl(radio); radio.click()
        } else {
            let button = surface.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 5), mainWindow.debugDescription)
            waitEnabled(button); revealOptionControl(button); button.click()
        }
    }
    /// Resolve the containing viewport rather than an unrelated nested editor.
    /// Pickers outside a ScrollView use the window and must already be visible.
    private func controlScrollView(_ element: XCUIElement) -> XCUIElement? {
        guard element.exists else {
            let scroll = mainWindow.scrollViews.firstMatch
            return scroll.exists ? scroll : nil
        }
        let key = element.identifier.isEmpty ? element.label : element.identifier
        guard !key.isEmpty else { return nil }
        let scroll = mainWindow.scrollViews.containing(element.elementType, identifier: key).firstMatch
        return scroll.exists ? scroll : nil
    }
    /// Input-page actions stay in a fixed footer; other controls remain inside
    /// their scroll viewport, including expanded inputs and page navigation.
    private func revealOptionControl(_ element: XCUIElement) {
        let window = mainWindow.frame
        let fixedActionIDs: Set<String> = [
            "optionTradeRecord", "optionLabSave", "optionLabNew", "optionLabCalculate"
        ]
        if element.exists, fixedActionIDs.contains(element.identifier) {
            let viewport = window.insetBy(dx: 0, dy: 8)
            let frame = element.frame
            XCTAssertTrue(!frame.isEmpty && !viewport.isEmpty
                && viewport.contains(frame) && element.isHittable,
                "Fixed option action must be visible without scrolling: \(element.debugDescription)")
            return
        }
        // Resolving containment walks the AX tree. Do it once per action, not
        // repeatedly for each frame/visibility comparison in the scroll loop.
        let scroll = controlScrollView(element)
        let viewport = (scroll?.frame.intersection(window) ?? window).insetBy(dx: 0, dy: 8)
        guard !viewport.isEmpty else { XCTFail("Control has no visible viewport"); return }
        var previousFrame: CGRect?
        var unchangedFrames = 0
        for _ in 0..<40 {
            var distance: CGFloat = -120
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty && viewport.contains(frame) && element.isHittable { return }
                if frame == previousFrame { unchangedFrames += 1 } else { unchangedFrames = 0 }
                previousFrame = frame
                if unchangedFrames >= 3 { break }
                distance = viewport.midY - frame.midY
            }
            guard let scroll else { break }
            scroll.scroll(byDeltaX: 0, deltaY: max(-160, min(160, distance)))
        }
        XCTFail("Control must be visible before interaction: viewport=\(viewport), \(element.debugDescription)")
    }
    private func waitOptionInputSummary() {
        // Calculation intentionally stays on the input page. The full result
        // status is a separate, explicitly selected details view.
        waitText("示例数据", in: mainWindow.staticTexts["optionLabOrigin"])
        waitText("$", in: mainWindow.staticTexts["optionLabMaxProfit"])
        waitText("未保存", in: mainWindow.descendants(matching: .any)["optionReferenceSaveStatus"].firstMatch)
        XCTAssertFalse(mainWindow.staticTexts["optionLabReportStatus"].exists)
        waitEnabled(mainWindow.buttons["optionLabSave"])
        XCTAssertTrue(mainWindow.buttons["optionLabSave"].label.contains("不入账"))
        XCTAssertTrue(mainWindow.buttons["optionTradeRecord"].label.contains("确认开仓"))
    }
    private func saveOptionDraftFromInput() {
        researchTab("输入")
        let button = mainWindow.buttons["optionLabSave"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); waitEnabled(button)
        revealOptionControl(button); button.click(); waitEnabled(button, false)
        waitText("已保存", in: mainWindow.descendants(matching: .any)["optionReferenceSaveStatus"].firstMatch)
        waitText("未入账", in: mainWindow.descendants(matching: .any)["optionReferenceSaveStatus"].firstMatch)
    }
    private func waitText(_ text: String, in element: XCUIElement) {
        // AppKit static text may expose its contents as AXValue, not AXTitle.
        let predicate = NSPredicate { _, _ in
            element.exists && (element.label.contains(text) || (element.value as? String)?.contains(text) == true)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 15)
        XCTAssertEqual(result, .completed, element.debugDescription)
    }
    private func selectPage(_ identifier: String) {
        let page = mainWindow.buttons[identifier]
        XCTAssertTrue(page.waitForExistence(timeout: 15)); waitEnabled(page)
        XCTAssertTrue(page.isHittable, mainWindow.debugDescription); page.click()
    }
    private func expandDisclosure(_ identifier: String, revealing child: XCUIElement) {
        if child.exists { return }
        let container = mainWindow.descendants(matching: .any)[identifier].firstMatch
        let button = mainWindow.buttons[identifier].firstMatch
        // A native DisclosureGroup can itself be the identified triangle; it
        // does not contain a second triangle below it in the AX hierarchy.
        let nativeTriangle = mainWindow.disclosureTriangles[identifier].firstMatch
        let disclosure = button.exists ? button
            : (nativeTriangle.exists ? nativeTriangle : container.disclosureTriangles.firstMatch)
        revealOptionControl(disclosure)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), mainWindow.debugDescription)
        waitEnabled(disclosure)
        func expandedState() -> Bool? {
            if let value = disclosure.value as? NSNumber { return value.boolValue }
            if let value = disclosure.value as? String {
                if value == "0" || value == "已收起" { return false }
                if value == "1" || value == "已展开" { return true }
            }
            return nil
        }
        guard let expanded = expandedState() else {
            XCTFail("Disclosure has no readable expanded state: \(disclosure.debugDescription)")
            return
        }
        if !expanded { disclosure.click() }
        let opened = NSPredicate { _, _ in disclosure.exists && expandedState() == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opened, object: disclosure)], timeout: 5),
                       .completed, disclosure.debugDescription)
        // Expanded lazy content may not yet be present in the AX tree. Scroll
        // its existing parent until it materializes; do not toggle it closed.
        let scroll = controlScrollView(disclosure)
        for _ in 0..<24 {
            if child.exists { return }
            guard let scroll else { break }
            scroll.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(child.waitForExistence(timeout: 5), "Expanded content is missing: \(child.debugDescription)")
    }
    private func openStockTool(_ identifier: String, title: String) {
        let tools = mainWindow.descendants(matching: .any)["stockAdvancedTools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); waitEnabled(tools)
        let ready = NSPredicate { _, _ in tools.exists && tools.isEnabled && tools.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: tools)], timeout: 5),
                       .completed, mainWindow.debugDescription)
        tools.click()
        let destination = app.menuItems.matching(NSPredicate(format: "identifier == %@ OR title == %@",
            identifier, title)).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.click()
    }
    private func openStockDemo() {
        selectPage("pageStocks")
        openStockTool("stockOpenDemo", title: "合成研究与自选管理")
        XCTAssertTrue(mainWindow.staticTexts["researchCompany"].waitForExistence(timeout: 15))
    }

    private func checkSECFailureKeepsIndependentToolsReachable() {
        app.terminate()
        configure()
        app.launchArguments.append("--synthetic-sec-init-failure")
        launchMainWindow(); selectPage("pageStocks")
        let error = mainWindow.descendants(matching: .any)["secPreparationError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), mainWindow.debugDescription)
        XCTAssertTrue(mainWindow.buttons["secPreparationRetry"].isEnabled)
        XCTAssertTrue(mainWindow.staticTexts["stockAnalysisTitle"].exists)

        // Reach an independently opened SQLite archive, then the in-memory watchlist.
        // Merely observing the menu does not establish that either destination works.
        openStockTool("stockOpenOffline", title: "离线财报摘录")
        XCTAssertTrue(mainWindow.descendants(matching: .any)["offlineIssuerPicker"].firstMatch.waitForExistence(timeout: 15))
        let generate = mainWindow.buttons["offlineGenerate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5)); waitEnabled(generate)
        XCTAssertFalse(error.exists)
        mainWindow.buttons["stockBackToAnalysis"].click()
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        openStockTool("stockOpenDemo", title: "合成研究与自选管理")
        XCTAssertTrue(mainWindow.staticTexts["researchCompany"].waitForExistence(timeout: 15))
        XCTAssertFalse(error.exists)
        researchTab("自选")
        let addWatch = mainWindow.buttons["researchAddWatch"]
        XCTAssertTrue(addWatch.waitForExistence(timeout: 5)); waitEnabled(addWatch)
        mainWindow.buttons["stockBackToAnalysis"].click()
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(mainWindow.buttons["secPreparationRetry"].isEnabled)
        // The broken SEC database is still rejected after returning; no reset or repair.
        XCTAssertTrue(mainWindow.staticTexts["stockAnalysisTitle"].exists)
    }
    private func launchResearch() {
        configure(); launchMainWindow(); openStockDemo()
    }
    private func openMarketTools() {
        selectPage("pageSettings")
        let open = mainWindow.buttons["settingsOpenMarket"]
        if !open.exists {
            let disclosure = mainWindow.buttons["settingsAdvancedTools"]
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10)); disclosure.click()
        }
        XCTAssertTrue(open.waitForExistence(timeout: 5)); waitEnabled(open); open.click()
        XCTAssertTrue(mainWindow.staticTexts["marketTitle"].waitForExistence(timeout: 15))
    }
    private func navigateInvestmentSection(_ section: String) {
        selectPage("pageInvestments")
        let id = section == "收益分析" ? "pagePortfolio" : "pageLedger"
        let title = section == "收益分析" ? "收益、估值证据与历史报告" : "交易账本"
        openInvestmentTool(id, title: title)
    }
    private func openInvestmentTool(_ id: String, title: String) {
        let tools = mainWindow.descendants(matching: .any)["investmentAdvanced"].firstMatch
        let scroll = mainWindow.scrollViews.firstMatch
        func toolsFullyVisible() -> Bool {
            guard tools.exists, scroll.exists else { return false }
            let viewport = scroll.frame.intersection(mainWindow.frame).insetBy(dx: 0, dy: 8)
            return !tools.frame.isEmpty && !viewport.isEmpty && viewport.contains(tools.frame)
        }
        for _ in 0..<20 where !toolsFullyVisible() { scroll.scroll(byDeltaX: 0, deltaY: -100) }
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        XCTAssertTrue(toolsFullyVisible() && tools.isHittable, mainWindow.debugDescription)
        tools.click()
        let item = app.menuItems.matching(NSPredicate(format: "identifier == %@ OR title == %@", id, title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
    }
    private func closeInvestmentDetail() {
        let back = mainWindow.buttons["investmentBack"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.click()
        waitAbsent(back)
    }
    private func waitAbsent(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    func testThreeDailyEntrancesKeepAdvancedToolsCollapsedAndReturn() {
        configure(); launchMainWindow()
        func attachWindow(_ name: String) {
            // Only this isolated synthetic host's window; never the desktop,
            // real account data, or an external upload/share operation.
            let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for id in ["pageInvestments", "pageOptions", "pageStocks", "pageSettings"] {
            XCTAssertTrue(mainWindow.buttons[id].waitForExistence(timeout: 15))
        }
        for retired in ["pageWorkspace", "pageResearch", "pageOfflineResearch", "pageSECResearch", "pageLedger", "pagePortfolio", "pageMarket"] {
            XCTAssertFalse(mainWindow.buttons[retired].exists)
        }
        XCTAssertTrue(mainWindow.buttons["investmentRecord"].waitForExistence(timeout: 15))
        attachWindow("DailyWorkflow-Investments-Empty")
        selectPage("pageOptions")
        XCTAssertTrue(mainWindow.buttons["optionLabInputTab"].waitForExistence(timeout: 15))
        XCTAssertFalse(mainWindow.buttons["optionLabAdvanced-数据对照"].exists)
        XCTAssertFalse(mainWindow.buttons["optionLabAdvanced-期权归档"].exists)
        XCTAssertFalse(mainWindow.textFields["optionLabPricingRate"].exists)
        attachWindow("DailyWorkflow-Options-Offline")
        researchTab("数据对照")
        XCTAssertTrue(mainWindow.buttons["optionEvidenceTemplate"].waitForExistence(timeout: 15))
        researchTab("输入")
        XCTAssertTrue(mainWindow.textFields["optionLabSymbol"].waitForExistence(timeout: 10))
        XCTAssertFalse(mainWindow.buttons["optionEvidenceTemplate"].exists)
        selectPage("pageStocks")
        XCTAssertTrue(mainWindow.staticTexts["stockAnalysisTitle"].waitForExistence(timeout: 15))
        XCTAssertFalse(mainWindow.textFields["secContactEmail"].exists)
        XCTAssertFalse(mainWindow.descendants(matching: .any)["stockOverviewMetrics"].firstMatch.exists)
        attachWindow("DailyWorkflow-Stocks-Empty")
        openStockDemo()
        let back = mainWindow.buttons["stockBackToAnalysis"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.click()
        XCTAssertTrue(mainWindow.staticTexts["stockAnalysisTitle"].waitForExistence(timeout: 15))
        selectPage("pageSettings")
        XCTAssertTrue(mainWindow.buttons["settingsAdvancedTools"].waitForExistence(timeout: 10))
        XCTAssertFalse(mainWindow.buttons["settingsOpenMarket"].exists)
        openMarketTools()
        let returnToSettings = mainWindow.buttons["settingsBack"]
        XCTAssertTrue(returnToSettings.waitForExistence(timeout: 5)); returnToSettings.click()
        XCTAssertTrue(mainWindow.secureTextFields["credentialInput"].waitForExistence(timeout: 10))
        selectPage("pageInvestments")
        XCTAssertTrue(mainWindow.buttons["investmentRecord"].waitForExistence(timeout: 15))
        checkSECFailureKeepsIndependentToolsReachable()
    }
    func testPortfolioSyntheticExampleNeverBecomesAnAccountReport() {
        configure(); launchMainWindow()
        navigateInvestmentSection("收益分析")
        let demo = mainWindow.buttons["portfolioDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); waitEnabled(demo); demo.click()
        waitText("SYNTHETIC", in: mainWindow.staticTexts["portfolioOrigin"])
        waitText("1004", in: mainWindow.staticTexts["portfolioNAV"])
        XCTAssertFalse(mainWindow.buttons["portfolioSavePreview"].exists)
        researchTab("收益与风险")
        let month = mainWindow.staticTexts["2026-01"]
        for _ in 0..<8 where !month.isHittable { mainWindow.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        closeInvestmentDetail()
        selectPage("pageStocks")
        navigateInvestmentSection("收益分析")
        XCTAssertTrue(demo.waitForExistence(timeout: 15)); waitEnabled(demo)
        XCTAssertFalse(mainWindow.staticTexts["portfolioNAV"].exists)
        XCTAssertFalse(mainWindow.buttons["portfolioSavePreview"].exists)
    }
    func testLedgerPreviewCancelCommitAndPageReopenStayLocal() {
        configure(); launchMainWindow()
        navigateInvestmentSection("交易记录")
        let name = mainWindow.textFields["ledgerAccountName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); waitEnabled(name)
        XCTAssertFalse(mainWindow.textFields["ledgerAccountID"].exists)
        XCTAssertFalse(mainWindow.descendants(matching: .any)["ledgerSections"].firstMatch.exists)
        let create = mainWindow.buttons["ledgerCreateAccount"]
        XCTAssertFalse(create.isEnabled)
        name.click(); name.typeText("Synthetic ledger")
        waitEnabled(create); create.click()
        let cash = mainWindow.staticTexts["ledgerCash"]
        waitText("0 USD", in: cash)
        researchTab("CSV 导入")
        let template = mainWindow.buttons["填入合成模板"]
        XCTAssertTrue(template.waitForExistence(timeout: 5)); template.click()
        let preview = mainWindow.buttons["ledgerPreviewCSV"]
        func reach(_ element: XCUIElement) {
            for _ in 0..<14 {
                if element.isHittable { break }
                mainWindow.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(element.isHittable, mainWindow.debugDescription)
        }
        reach(preview); waitEnabled(preview); preview.click()
        let expectedCash = mainWindow.staticTexts["ledgerPreviewCash"]
        waitText("980 USD", in: expectedCash)
        let cancel = mainWindow.buttons["ledgerCancelPreview"]
        reach(cancel); cancel.click()
        researchTab("现金与批次"); waitText("0 USD", in: cash)
        researchTab("CSV 导入"); reach(preview); waitEnabled(preview); preview.click()
        waitText("980 USD", in: expectedCash)
        let review = mainWindow.buttons["ledgerReviewCommit"]
        reach(review); waitEnabled(review); review.click()
        let panel = app.sheets.containing(.button, identifier: "ledgerCommit").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let commit = panel.buttons["ledgerCommit"]
        XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(panel.exists)
        let confirmation = panel.textFields["ledgerConfirmText"]
        confirmation.click(); confirmation.typeText("入账"); waitEnabled(commit); commit.click()
        waitAbsent(panel)
        researchTab("现金与批次"); waitText("980 USD", in: cash)
        closeInvestmentDetail()
        selectPage("pageStocks")
        XCTAssertTrue(mainWindow.buttons["pageInvestments"].exists)
        navigateInvestmentSection("交易记录")
        waitText("980 USD", in: cash)
        XCTAssertFalse(mainWindow.buttons["ledgerReviewCommit"].exists)
        // Only in-app preview/confirmation: never opens an import/export panel.
        researchTab("导出与备份")
        let clearPreview = mainWindow.buttons["ledgerArchiveClearPreview"]
        XCTAssertTrue(clearPreview.waitForExistence(timeout: 10))
        reach(clearPreview); waitEnabled(clearPreview); clearPreview.click()
        let archiveSheet = app.sheets.containing(.button, identifier: "ledgerArchiveCommit").firstMatch
        XCTAssertTrue(archiveSheet.waitForExistence(timeout: 5))
        let clearCommit = archiveSheet.buttons["ledgerArchiveCommit"]
        XCTAssertTrue(clearCommit.waitForExistence(timeout: 5), archiveSheet.debugDescription)
        XCTAssertFalse(clearCommit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(archiveSheet.exists)
        archiveSheet.buttons["ledgerArchiveCancel"].click(); waitAbsent(archiveSheet)
        researchTab("现金与批次"); waitText("980 USD", in: cash)
        researchTab("导出与备份"); reach(clearPreview); waitEnabled(clearPreview); clearPreview.click()
        XCTAssertTrue(archiveSheet.waitForExistence(timeout: 5))
        let clearText = archiveSheet.textFields["ledgerArchiveConfirmText"]
        XCTAssertTrue(clearText.waitForExistence(timeout: 5), archiveSheet.debugDescription)
        clearText.click(); clearText.typeText("确认"); waitEnabled(clearCommit); clearCommit.click()
        waitAbsent(archiveSheet)
        researchTab("现金与批次")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(mainWindow.textFields["ledgerAccountID"].exists)
        XCTAssertFalse(mainWindow.descendants(matching: .any)["ledgerSections"].firstMatch.exists)
        XCTAssertFalse(create.isEnabled)
        XCTAssertFalse(cash.exists)
    }
    func testInvestmentDailyAccountEvidenceSaveShareAndReuseKeepConfirmationBoundaries() {
        configure(); launchMainWindow(); selectPage("pageInvestments")
        let share = mainWindow.buttons["investmentShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); waitEnabled(share, false)
        let record = mainWindow.buttons["investmentRecord"]
        waitEnabled(record); record.click()
        let accountName = mainWindow.textFields["ledgerAccountName"]
        XCTAssertTrue(accountName.waitForExistence(timeout: 10)); waitEnabled(accountName)
        accountName.click(); accountName.typeText("Daily workflow test")
        let create = mainWindow.buttons["ledgerCreateAccount"]
        waitEnabled(create); create.click()
        let next = mainWindow.buttons["ledgerContinueCalculation"]
        XCTAssertTrue(next.waitForExistence(timeout: 5)); waitEnabled(next); next.click()

        // An explicitly empty local account avoids market observations entirely.
        // The input is test-only user-confirmed material, never a relabelled demo.
        let scroll = mainWindow.scrollViews.firstMatch
        func reach(_ element: XCUIElement) {
            func viewport() -> CGRect { scroll.frame.intersection(mainWindow.frame).insetBy(dx: 0, dy: 8) }
            func visible() -> Bool {
                element.exists && element.isHittable && !element.frame.isEmpty && viewport().contains(element.frame)
            }
            for _ in 0..<24 {
                if visible() { break }
                let offset = element.exists ? viewport().midY - element.frame.midY : -120
                scroll.scroll(byDeltaX: 0, deltaY: max(-180, min(180, offset)))
            }
            XCTAssertTrue(visible(), "Investment input must be wholly visible before native interaction: \(element.debugDescription)")
        }
        func fill(_ element: XCUIElement, _ value: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 5)); reach(element)
            if element.elementType == .textView {
                // The date field and editors share the same production blocked
                // gate. Check that gate, then prove native TextEditor editing by
                // reading back its value instead of relying on AXEnabled alone.
                waitEnabled(mainWindow.textFields["investmentStartDay"])
                XCTAssertFalse(mainWindow.descendants(matching: .any)["investmentCalculationStale"].exists)
            } else {
                waitEnabled(element)
            }
            element.click(); element.typeKey("a", modifierFlags: .command); element.typeText(value)
            let updated = NSPredicate { _, _ in (element.value as? String) == value }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updated, object: element)], timeout: 5),
                           .completed, "Investment input did not accept the entered value: \(element.debugDescription)")
        }
        func evidence(_ prefix: String, reference: String) {
            let source = mainWindow.textFields[prefix + "Source"]
            expandDisclosure(prefix + "Details", revealing: source)
            fill(source, "Local test record")
            fill(mainWindow.textFields[prefix + "Reference"], reference)
            fill(mainWindow.textFields[prefix + "AvailableAt"], "2026-01-01T00:00:00Z")
            fill(mainWindow.textViews[prefix + "Text"], "Explicit test-only " + reference)
        }
        let calendar = mainWindow.textViews["investmentCalendarDays"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        fill(calendar, "2026-01-05\n2026-01-06")
        evidence("investmentCalendar", reference: "calendar-v1")
        let inspect = mainWindow.buttons["investmentInspectMissing"]
        reach(inspect); inspect.click()
        for day in ["2026-01-05", "2026-01-06"] {
            let instant = mainWindow.textFields["investmentValuation-" + day]
            XCTAssertTrue(instant.waitForExistence(timeout: 5))
            XCTAssertEqual(instant.value as? String, "") // No current date or close time is invented.
            fill(instant, day + "T21:00:00Z")
        }
        let flows = mainWindow.checkBoxes["investmentConfirmFlows"]
        XCTAssertTrue(flows.waitForExistence(timeout: 5)); XCTAssertEqual(flows.value as? String, "0")
        evidence("investmentFlow", reference: "empty-account-flows-v1")
        reach(flows); flows.click()
        let calculate = mainWindow.buttons["investmentCalculate"]
        reach(calculate); waitEnabled(calculate); calculate.click()
        waitText("0.00 USD", in: mainWindow.staticTexts["investmentCalculationPnL"])
        let review = mainWindow.buttons["investmentSaveCalculation"]
        reach(review); waitEnabled(review); review.click()
        let confirmation = mainWindow.sheets.containing(.button, identifier: "investmentConfirmSave").firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let commit = confirmation.buttons["investmentConfirmSave"]
        XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(confirmation.exists)
        let text = confirmation.textFields["investmentSaveConfirmation"]
        text.click(); text.typeText("保存"); waitEnabled(commit); commit.click()
        waitAbsent(confirmation)
        XCTAssertTrue(share.waitForExistence(timeout: 10)); waitEnabled(share)
        waitText("0.00", in: mainWindow.staticTexts["investmentNetPnL"])
        // Full valuation cards retain their own saved/replayed-report gate.
        let frozenShare = mainWindow.buttons["investmentShareFrozen"]
        expandDisclosure("investmentPeriodReport", revealing: frozenShare)
        reach(frozenShare); waitEnabled(frozenShare); frozenShare.click()
        let sharing = mainWindow.sheets.containing(.button, identifier: "investmentShareCopy").firstMatch
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        XCTAssertTrue(sharing.descendants(matching: .any)["investmentSharePreview"].exists)
        XCTAssertTrue(sharing.staticTexts["金额已隐藏"].exists)
        XCTAssertFalse(sharing.staticTexts["Daily workflow test"].exists)
        XCTAssertEqual(sharing.descendants(matching: .any)["investmentShareHideAmounts"].value as? String, "1")
        XCTAssertEqual(sharing.checkBoxes["investmentShareHoldings"].value as? String, "0")
        // Preview only: no clipboard mutation, browser launch, file panel or post.
        sharing.buttons["investmentShareClose"].click(); waitAbsent(sharing)
        // Quick cards use booked P&L only, without promoting their results to
        // complete valuation, return-rate or frozen-report evidence.
        let quick = mainWindow.buttons["investmentGenerateReport"]
        func waitReportAction(_ element: XCUIElement) {
            let ready = NSPredicate { _, _ in element.exists && element.isEnabled && element.isHittable }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)], timeout: 10),
                           .completed, element.debugDescription)
        }
        XCTAssertTrue(quick.waitForExistence(timeout: 5)); waitEnabled(quick); quick.click()
        let quickSheet = mainWindow.sheets.containing(.button, identifier: "investmentQuickReportsClose").firstMatch
        XCTAssertTrue(quickSheet.waitForExistence(timeout: 5))
        for period in ["year", "quarter", "month"] {
            waitText("$0.00", in: quickSheet.staticTexts["investmentQuickReport-" + period])
            XCTAssertTrue(quickSheet.buttons["investmentQuickShare-" + period].exists)
        }
        XCTAssertFalse(quickSheet.textViews["investmentCalendarDays"].exists)
        XCTAssertFalse(quickSheet.textFields["investmentStartDay"].exists)
        XCTAssertFalse(quickSheet.buttons["investmentConfirmSave"].exists)
        let monthShare = quickSheet.buttons["investmentQuickShare-month"]
        waitEnabled(monthShare); monthShare.click()
        // Native nested sheets may be exposed as siblings or descendants.
        // Use unique controls and the card itself, not an ancestor's sheet match.
        let quickPreview = mainWindow.descendants(matching: .any)["investmentSharePreview"].firstMatch
        let shareClose = mainWindow.buttons["investmentShareClose"]
        XCTAssertTrue(quickPreview.waitForExistence(timeout: 5))
        XCTAssertTrue(quickPreview.staticTexts["已入账收益"].exists)
        waitText("金额已隐藏", in: quickPreview.staticTexts["investmentShareTotal"])
        XCTAssertFalse(mainWindow.checkBoxes["investmentShareReturn"].exists)
        XCTAssertFalse(mainWindow.checkBoxes["investmentShareHoldings"].exists)
        XCTAssertFalse(quickPreview.staticTexts["Daily workflow test"].exists)
        let amounts = mainWindow.descendants(matching: .any)["investmentShareHideAmounts"].firstMatch
        XCTAssertEqual(amounts.value as? String, "1")
        for index in 0..<3 {
            waitText("金额已隐藏", in: quickPreview.staticTexts["investmentShareBreakdown-\(index)"])
        }
        amounts.click()
        waitText("0.00 USD", in: quickPreview.staticTexts["investmentShareTotal"])
        // Native preview only: changing periods must recheck storage and retain
        // privacy settings. Do not open the save panel or invoke clipboard/X.
        for (period, title) in [("year", "近1年"), ("quarter", "近1季度"), ("month", "近1个月")] {
            let select = mainWindow.buttons["investmentSharePeriod-" + period]
            waitEnabled(select); select.click()
            waitText(title, in: quickPreview.staticTexts["investmentShareCardPeriod"])
            waitText("0.00 USD", in: quickPreview.staticTexts["investmentShareTotal"])
        }
        amounts.click()
        waitText("金额已隐藏", in: quickPreview.staticTexts["investmentShareTotal"])
        for index in 0..<3 {
            waitText("金额已隐藏", in: quickPreview.staticTexts["investmentShareBreakdown-\(index)"])
        }
        waitEnabled(mainWindow.buttons["investmentShareSave"])
        waitEnabled(shareClose); shareClose.click(); waitAbsent(shareClose)
        waitAbsent(quickPreview)
        quickSheet.buttons["investmentQuickReportsClose"].click(); waitAbsent(quickSheet)
        // The ordinary report must finish its loading-to-table transition and
        // return control to the main window on every presentation. Merely
        // finding three values does not prove the sheet can still be dismissed.
        for _ in 0..<3 {
            waitReportAction(quick); quick.click()
            XCTAssertTrue(quickSheet.waitForExistence(timeout: 5))
            for period in ["year", "quarter", "month"] {
                waitText("$0.00", in: quickSheet.staticTexts["investmentQuickReport-" + period])
                XCTAssertTrue(quickSheet.buttons["investmentQuickShare-" + period].exists)
            }
            waitAbsent(quickSheet.descendants(matching: .any)["investmentQuickReportsLoading"].firstMatch)
            XCTAssertFalse(quickSheet.staticTexts["investmentQuickReportsError"].exists)
            let closeReport = quickSheet.buttons["investmentQuickReportsClose"]
            waitReportAction(closeReport); closeReport.click(); waitAbsent(quickSheet)
            waitReportAction(quick)
        }
        waitEnabled(share)
        // Fast, read-only generation must reach the card without observing a
        // transient busy edge. Reopening starts a fresh presentation each time.
        for _ in 0..<3 {
            waitReportAction(share); share.click()
            XCTAssertTrue(quickPreview.waitForExistence(timeout: 10))
            waitAbsent(mainWindow.descendants(matching: .any)["investmentQuickReportsLoading"].firstMatch)
            XCTAssertFalse(mainWindow.staticTexts["investmentQuickReportsError"].exists)
            waitText("近1个月", in: quickPreview.staticTexts["investmentShareCardPeriod"])
            waitText("金额已隐藏", in: quickPreview.staticTexts["investmentShareTotal"])
            waitReportAction(shareClose); shareClose.click(); waitAbsent(quickPreview)
            waitReportAction(quick)
        }
        waitText("0.00", in: mainWindow.staticTexts["investmentNetPnL"])
        openInvestmentTool("investmentStartCalculation", title: "补齐数据并核算")
        let reuse = mainWindow.buttons["investmentReuseEvidence"]
        XCTAssertTrue(reuse.waitForExistence(timeout: 10)); waitEnabled(reuse); reuse.click()
        XCTAssertTrue(mainWindow.descendants(matching: .any)["investmentReusedStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(mainWindow.textFields["investmentStartDay"].value as? String, "2026-01-05")
        XCTAssertEqual(mainWindow.textFields["investmentEndDay"].value as? String, "2026-01-06")
        XCTAssertFalse(calendar.exists)
        XCTAssertFalse(mainWindow.textFields["investmentValuation-2026-01-05"].exists)
        XCTAssertEqual(flows.value as? String, "0") // Reuse never re-approves completeness.
        reach(calculate); waitEnabled(calculate); calculate.click()
        waitText("待补数据", in: mainWindow.staticTexts["investmentCalculationPnL"])
    }
    func testOptionEvidenceOfflineKindsFreezeReplayAndDraftInvalidation() {
        configure(); launchMainWindow()
        XCTAssertTrue(mainWindow.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["optionLabTemplate"].waitForExistence(timeout: 15))
        researchTab("数据对照")
        let template = mainWindow.buttons["optionEvidenceTemplate"]
        let calculate = mainWindow.buttons["optionEvidenceCalculate"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template)
        revealOptionControl(template); template.click(); waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        XCTAssertTrue(mainWindow.staticTexts["optionEvidenceProviderTitle"].waitForExistence(timeout: 15))
        waitText("SYNTHETIC", in: mainWindow.staticTexts["optionEvidenceOrigin"])
        let save = mainWindow.buttons["optionEvidenceSave"]
        waitEnabled(save); revealOptionControl(save); save.click(); waitEnabled(save, false)
        waitText("完整重放核对", in: mainWindow.staticTexts["optionEvidenceReplay"])
        researchTab("25-Delta 波动率")
        XCTAssertFalse(mainWindow.staticTexts["optionEvidenceProviderTitle"].exists)
        waitEnabled(calculate, false)
        waitEnabled(template); revealOptionControl(template); template.click(); waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        XCTAssertTrue(mainWindow.staticTexts["optionEvidenceDeltaTitle"].waitForExistence(timeout: 15))
        waitText("Call IV", in: mainWindow.staticTexts["optionEvidenceDeltaValues"])
        researchTab("交易时点归因")
        XCTAssertFalse(mainWindow.staticTexts["optionEvidenceDeltaTitle"].exists)
        waitEnabled(template); revealOptionControl(template); template.click(); waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        XCTAssertTrue(mainWindow.staticTexts["optionEvidenceAttributionTitle"].waitForExistence(timeout: 15))
        // Reload clears unsaved numbers; catalog rows alone cannot publish cached results.
        let scroll = mainWindow.scrollViews.firstMatch
        let reload = mainWindow.buttons["optionEvidenceReload"]
        for _ in 0..<24 where !reload.exists || !reload.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -150) }
        XCTAssertTrue(reload.exists && reload.isHittable, mainWindow.debugDescription)
        waitEnabled(reload); revealOptionControl(reload); reload.click()
        let open = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "optionEvidenceOpen-")).firstMatch
        for _ in 0..<24 where !open.exists || !open.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -100) }
        XCTAssertTrue(open.exists && open.isHittable, mainWindow.debugDescription)
        waitEnabled(open); open.click()
        let status = mainWindow.staticTexts["optionEvidenceReplay"]
        for _ in 0..<24 where !status.exists || !status.isHittable { scroll.scroll(byDeltaX: 0, deltaY: 150) }
        waitText("完整重放核对", in: status)
        XCTAssertTrue(mainWindow.staticTexts["optionEvidenceProviderTitle"].exists)
        // Opening the provider report also synchronizes the kind picker. A deliberate
        // switch invalidates that reopened result and leaves no enabled save action.
        researchTab("25-Delta 波动率")
        XCTAssertFalse(mainWindow.staticTexts["optionEvidenceProviderTitle"].exists)
        waitEnabled(save, false)
    }
    func testPortfolioGreeksCoverageFrozenReplayAndSyntheticIsolation() {
        configure(); launchMainWindow()
        XCTAssertTrue(mainWindow.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["optionLabTemplate"].waitForExistence(timeout: 15))
        researchTab("组合风险")
        let complete = mainWindow.buttons["portfolioGreeksSyntheticComplete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 15)); waitEnabled(complete); revealOptionControl(complete); complete.click()
        waitText("SYNTHETIC", in: mainWindow.staticTexts["portfolioGreeksOrigin"])
        waitText("声明持仓范围完整覆盖", in: mainWindow.staticTexts["portfolioGreeksCompleteness"])
        let save = mainWindow.buttons["portfolioGreeksSave"]
        waitEnabled(save); revealOptionControl(save); save.click(); waitEnabled(save, false)
        waitText("完整重放核对", in: mainWindow.staticTexts["portfolioGreeksReplayStatus"])
        let missing = mainWindow.buttons["portfolioGreeksSyntheticMissing"]
        waitEnabled(missing); revealOptionControl(missing); missing.click()
        waitText("覆盖不完整", in: mainWindow.staticTexts["portfolioGreeksCompleteness"])
        waitText("缺口 1", in: mainWindow.staticTexts["portfolioGreeksCoverage"])
        waitEnabled(save)
        // Leaving invalidates this unsaved example. Reopening cannot publish catalog values.
        app.typeKey("1", modifierFlags: .command); app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["optionLabTemplate"].waitForExistence(timeout: 15))
        researchTab("组合风险")
        XCTAssertTrue(complete.waitForExistence(timeout: 15)); waitEnabled(complete)
        XCTAssertFalse(mainWindow.staticTexts["portfolioGreeksNetDelta"].exists)
        let open = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "portfolioGreeksOpen-")).firstMatch
        let scroll = mainWindow.scrollViews.firstMatch
        for _ in 0..<18 where !open.exists || !open.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -80) }
        XCTAssertTrue(open.exists && open.isHittable, mainWindow.debugDescription)
        waitEnabled(open); open.click()
        let status = mainWindow.staticTexts["portfolioGreeksReplayStatus"]
        for _ in 0..<18 where !status.exists || !status.isHittable { scroll.scroll(byDeltaX: 0, deltaY: 80) }
        waitText("完整重放核对", in: status)
        waitText("声明持仓范围完整覆盖", in: mainWindow.staticTexts["portfolioGreeksCompleteness"])
        XCTAssertFalse(save.isEnabled)
        // Explicit source reports and synthetic ledger evidence only; no file panel, real ledger mutation or network.
    }
    func testOptionChainExplicitSelectionReplayAndDraftHandoff() {
        configure(); launchMainWindow()
        XCTAssertTrue(mainWindow.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["optionLabTemplate"].waitForExistence(timeout: 15))
        researchTab("期权链")
        let load = mainWindow.buttons["optionChainLoadSynthetic"]
        XCTAssertTrue(load.waitForExistence(timeout: 15)); waitEnabled(load); load.click()
        waitText("SYNTHETIC", in: mainWindow.staticTexts["optionChainOrigin"])
        waitText("声明范围完整", in: mainWindow.staticTexts["optionChainCoverage"])
        let handoff = mainWindow.buttons["optionChainHandOff"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 5)); XCTAssertFalse(handoff.isEnabled)
        let saveCapture = mainWindow.buttons["optionChainSave"]
        waitEnabled(saveCapture); saveCapture.click(); waitEnabled(saveCapture, false)
        waitText("已保存采集", in: mainWindow.staticTexts["optionChainSavedStatus"])
        researchTab("采集目录")
        let reload = mainWindow.buttons["optionChainReload"]
        waitEnabled(reload); reload.click()
        let open = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "optionChainOpen-")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15)); waitEnabled(open); open.click()
        waitText("SYNTHETIC", in: mainWindow.staticTexts["optionChainOrigin"])
        waitText("当前来源已完整重放核对", in: mainWindow.staticTexts["optionChainSavedStatus"])
        XCTAssertFalse(handoff.isEnabled) // Opening never silently chooses the first contract.
        let scroll = mainWindow.scrollViews.element(boundBy: 0)
        func reveal(_ element: XCUIElement, delta: CGFloat) {
            for _ in 0..<24 where !element.exists || !element.isHittable { scroll.scroll(byDeltaX: 0, deltaY: delta) }
            XCTAssertTrue(element.exists && element.isHittable, mainWindow.debugDescription)
        }
        let expiry = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "optionChainExpiry-")).firstMatch
        reveal(expiry, delta: -80); expiry.click()
        let short = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "optionChainShort-")).firstMatch
        reveal(short, delta: -80); short.click()
        reveal(handoff, delta: 80); waitEnabled(handoff); handoff.click()
        waitText("示例数据", in: mainWindow.staticTexts["optionLabOrigin"])
        let symbol = mainWindow.textFields["optionLabSymbol"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 5))
        XCTAssertFalse((symbol.value as? String ?? "").isEmpty)
        let settlement = mainWindow.textFields["optionLabSettlementAt"]
        expandDisclosure("optionLabQuoteDetails", revealing: settlement)
        reveal(settlement, delta: -80)
        XCTAssertEqual(settlement.value as? String, "") // No inferred 16:00 settlement.
        let saveExperiment = mainWindow.buttons["optionLabSave"]
        XCTAssertFalse(saveExperiment.isEnabled)
        let calculate = mainWindow.buttons["optionLabCalculate"]
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        XCTAssertTrue(mainWindow.staticTexts["optionLabInputError"].waitForExistence(timeout: 5))
        XCTAssertFalse(saveExperiment.isEnabled) // Missing assumptions do not produce a report.
        // No provider request, account, Keychain or file importer/exporter is invoked.
    }
    func testMacroSourceExplicitPreviewApprovalAndFrozenReleaseCycleReplay() {
        configure(); launchMainWindow()
        openMarketTools()
        XCTAssertTrue(mainWindow.staticTexts["marketTitle"].waitForExistence(timeout: 15))
        researchTab("来源导入")
        let template = mainWindow.buttons["macroSourceDemo"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template); template.click()
        let preview = mainWindow.buttons["macroSourcePreview"]
        waitEnabled(preview); preview.click()
        waitText("尚未保存", in: mainWindow.staticTexts["macroSourcePreviewState"])
        waitText("可用修订 2 条", in: mainWindow.staticTexts["macroSourceCounts"])
        waitText("SYNTHETIC", in: mainWindow.staticTexts["macroSourceOrigin"])
        let save = mainWindow.buttons["macroSourceSavePreview"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); waitEnabled(save)
        let scroll = mainWindow.scrollViews.element(boundBy: 0)
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        func clickFullyVisible(_ button: XCUIElement) {
            func fullyVisible() -> Bool {
                guard button.exists else { return false }
                let viewport = scroll.frame.intersection(mainWindow.frame).insetBy(dx: 0, dy: 12)
                return !viewport.isEmpty && !button.frame.isEmpty && viewport.contains(button.frame)
            }
            // macOS 15 can report isHittable while a catalog button is still
            // clipped by the scroll viewport. Never click that exposed sliver.
            for _ in 0..<30 {
                if fullyVisible() { break }
                guard button.exists else { XCTFail("Source action disappeared before scrolling"); return }
                let distance = scroll.frame.midY - button.frame.midY
                scroll.scroll(byDeltaX: 0, deltaY: max(-100, min(100, distance)))
            }
            waitEnabled(button)
            guard fullyVisible(), button.isHittable else {
                XCTFail("Source action is outside viewport: button=\(button.frame), scroll=\(scroll.frame)")
                return
            }
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        clickFullyVisible(save)
        let panel = sheet(in: mainWindow)
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let confirm = panel.buttons["macroSourceConfirmSave"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertFalse(confirm.isEnabled)
        app.typeKey(.return, modifierFlags: []); XCTAssertTrue(panel.exists)
        let text = panel.textFields["macroSourceConfirmText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.click(); text.typeText("确认")
        waitEnabled(confirm); confirm.click(); waitNoSheet(in: mainWindow)
        waitText("已保存来源", in: mainWindow.staticTexts["macroSourcePreviewState"])
        waitText("已冻结", in: mainWindow.staticTexts["macroSourceMessage"])
        let open = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "macroSourceOpen-")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        clickFullyVisible(open)
        waitText("完整重放", in: mainWindow.staticTexts["macroSourceMessage"])
        waitText("可用修订 2 条", in: mainWindow.staticTexts["macroSourceCounts"])
        // Uses only a fixed synthetic raw JSON template; no system file panel,
        // provider credential or network request is part of this test.
    }

    func testMarketStateMissingEvidenceFrozenReplayAndArchiveCancellation() {
        configure(); launchMainWindow()
        openMarketTools()
        let template = mainWindow.buttons["marketMissingDemo"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template); template.click()
        let calculate = mainWindow.buttons["marketCalculate"]
        waitEnabled(calculate); calculate.click()
        waitText("暂无可靠判断", in: mainWindow.staticTexts["marketRegime"])
        waitText("SYNTHETIC", in: mainWindow.staticTexts["marketOrigin"])
        let save = mainWindow.buttons["marketSave"]
        waitEnabled(save); save.click(); waitEnabled(save, false)
        waitText("已冻结", in: mainWindow.staticTexts["marketMessage"])
        researchTab("已保存快照")
        let open = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "marketOpen-")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); waitEnabled(open); open.click()
        waitText("完整输入重放核对通过", in: mainWindow.staticTexts["marketReplay"])
        waitText("暂无可靠判断", in: mainWindow.staticTexts["marketRegime"])
        researchTab("市场归档")
        waitText("市场快照 1", in: mainWindow.staticTexts["marketArchiveCounts"])
        let preview = mainWindow.buttons["marketArchiveClear"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); waitEnabled(preview)
        let scroll = mainWindow.scrollViews.element(boundBy: 0)
        for _ in 0..<20 where !preview.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -80) }
        XCTAssertTrue(preview.isHittable); preview.click()
        let panel = sheet(in: mainWindow)
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let commit = panel.buttons["marketArchiveCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5)); XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return, modifierFlags: []); XCTAssertTrue(panel.exists)
        panel.buttons["marketArchiveCancel"].click(); waitNoSheet(in: mainWindow)
        waitText("已取消预检计划", in: mainWindow.staticTexts["marketMessage"])
        waitText("市场快照 1", in: mainWindow.staticTexts["marketArchiveCounts"])
        // Does not open an importer, exporter or system file panel.
    }

    func testOptionDailySummaryReplayAndArchivePreviewCancellation() {
        configure(); launchMainWindow()
        XCTAssertTrue(mainWindow.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["optionLabTemplate"].waitForExistence(timeout: 15))
        researchTab("波动率历史")
        let template = mainWindow.buttons["optionDailyTemplate"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template); revealOptionControl(template); template.click()
        waitText("SYNTHETIC", in: mainWindow.staticTexts["optionDailyOrigin"])
        let calculate = mainWindow.buttons["optionDailyCalculate"]
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitText("25.00%", in: mainWindow.staticTexts["optionDailyResult"])
        let saveDaily = mainWindow.buttons["optionDailySave"]
        waitEnabled(saveDaily); revealOptionControl(saveDaily); saveDaily.click()
        waitText("日摘要已保存", in: mainWindow.staticTexts["optionHistoryMessage"])
        waitEnabled(saveDaily, false)
        researchTab("摘要目录")
        let reload = mainWindow.buttons["optionHistoryReload"]
        waitEnabled(reload); revealOptionControl(reload); reload.click()
        let openDaily = mainWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "optionDailyOpen-")).firstMatch
        XCTAssertTrue(openDaily.waitForExistence(timeout: 15)); waitEnabled(openDaily); revealOptionControl(openDaily); openDaily.click()
        waitText("完整输入重算并核对", in: mainWindow.staticTexts["optionHistoryMessage"])
        waitText("25.00%", in: mainWindow.staticTexts["optionDailyResult"])
        researchTab("期权归档")
        waitText("日摘要 1", in: mainWindow.staticTexts["optionArchiveCounts"])
        let preview = mainWindow.buttons["optionArchiveClearPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); waitEnabled(preview)
        let scroll = mainWindow.scrollViews.element(boundBy: 0)
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        func previewFullyVisible() -> Bool {
            guard preview.exists else { return false }
            let viewport = scroll.frame.intersection(mainWindow.frame).insetBy(dx: 0, dy: 8)
            return !viewport.isEmpty && !preview.frame.isEmpty && viewport.contains(preview.frame)
        }
        // macOS 15 reports a clipped button as hittable. Bring the whole action
        // into its viewport before clicking its center, not the exposed edge.
        for _ in 0..<20 where !previewFullyVisible() {
            guard preview.exists else { XCTFail("Archive action disappeared before scrolling"); return }
            let distance = scroll.frame.intersection(mainWindow.frame).midY - preview.frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: max(-100, min(100, distance)))
        }
        guard previewFullyVisible(), preview.isHittable else {
            XCTFail("Archive action is outside viewport: button=\(preview.frame), scroll=\(scroll.frame)")
            return
        }
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let confirmation = sheet(in: mainWindow)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10), mainWindow.debugDescription)
        let commit = confirmation.buttons["optionArchiveCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5)); XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(confirmation.exists)
        confirmation.buttons["optionArchiveCancel"].click(); waitNoSheet(in: mainWindow)
        waitText("预检已取消", in: mainWindow.staticTexts["optionArchiveMessage"])
        waitText("日摘要 1", in: mainWindow.staticTexts["optionArchiveCounts"])
        // No exporter/importer or actual file panel is invoked by this test.
    }
    private func checkCompactSinglePriceInputs() {
        let spot = mainWindow.textFields["optionReferenceUnderlyingPrice"]
        let premium = mainWindow.textFields["optionReferencePremiumPrice"]
        XCTAssertTrue(spot.waitForExistence(timeout: 10)); waitEnabled(spot)
        XCTAssertTrue(premium.waitForExistence(timeout: 5)); waitEnabled(premium)
        let quoteIDs = ["optionReferenceUnderlyingBid", "optionReferenceUnderlyingAsk",
                        "optionReferencePremiumBid", "optionReferencePremiumAsk"]
        for id in quoteIDs { XCTAssertFalse(mainWindow.textFields[id].exists) }
        revealOptionControl(spot); spot.click(); spot.typeText("45")
        revealOptionControl(premium); premium.click(); premium.typeText("0.7")
        let detailedResearch = mainWindow.buttons["optionUseDetailedResearch"]
        expandDisclosure("optionLabQuoteDetails", revealing: detailedResearch)
        XCTAssertTrue(detailedResearch.waitForExistence(timeout: 5)); waitEnabled(detailedResearch)
        // Default contract-only entry requires neither Bid/Ask nor account evidence.
        for id in quoteIDs { XCTAssertFalse(mainWindow.textFields[id].exists) }
        revealOptionControl(detailedResearch); detailedResearch.click()
        for id in quoteIDs {
            let field = mainWindow.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            // AppKit may expose an empty text field's prompt as its value.
            let value = field.value as? String ?? ""
            let prompt = id.hasSuffix("Bid") ? "Bid" : "Ask"
            XCTAssertTrue(value.isEmpty || value == prompt) // No manufactured Bid=Ask.
        }
        let details = mainWindow.buttons["optionLabQuoteDetails"]
        revealOptionControl(details); details.click()
        for id in quoteIDs { waitAbsent(mainWindow.textFields[id]) }
        XCTAssertEqual(spot.value as? String, "45")
        XCTAssertEqual(premium.value as? String, "0.7")
    }

    private func checkCompactExpiryFirstPresentation() {
        // Regression for the first popup capturing nil baseline/session state.
        // Exercise the blank manual form before loading any synthetic template.
        let expiry = mainWindow.buttons["optionReferenceExpiry"]
        XCTAssertTrue(expiry.waitForExistence(timeout: 10)); waitEnabled(expiry)
        revealOptionControl(expiry); expiry.click()
        let apply = app.buttons["optionReferenceExpiryApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); waitEnabled(apply)
        apply.click(); waitAbsent(apply)
        let appliedLabel = expiry.label
        XCTAssertFalse(appliedLabel.contains("选择到期时间"))
        XCTAssertFalse(appliedLabel.contains("时间格式待修正"))
        XCTAssertTrue(appliedLabel.contains("到期时间，美东时间，"))

        // Reopening must initialize from the applied value; cancel cannot clear it.
        expiry.click(); XCTAssertTrue(apply.waitForExistence(timeout: 5)); waitEnabled(apply)
        let cancel = app.buttons["optionReferenceExpiryCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.click(); waitAbsent(apply)
        XCTAssertEqual(expiry.label, appliedLabel)
        expiry.click(); XCTAssertTrue(apply.waitForExistence(timeout: 5)); waitEnabled(apply)
        apply.click(); waitAbsent(apply)
        XCTAssertEqual(expiry.label, appliedLabel)
    }

    func testOptionsLabExplicitCalculationFrozenReplayAndDraftInvalidation() {
        configure(); launchMainWindow()
        let navigation = app.buttons["pageOptions"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        let template = mainWindow.buttons["optionLabTemplate"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template)
        checkCompactSinglePriceInputs()
        checkCompactExpiryFirstPresentation()
        revealOptionControl(template); template.click()
        let saveSnapshot = mainWindow.buttons["optionLabSave"]
        XCTAssertFalse(saveSnapshot.isEnabled)
        let calculate = mainWindow.buttons["optionLabCalculate"]
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("结果")
        let status = mainWindow.staticTexts["optionLabReportStatus"]
        waitText("SYNTHETIC", in: status)
        saveOptionDraftFromInput()
        researchTab("结果"); waitText("已按完整输入重算", in: status)
        let screenshot = XCTAttachment(screenshot: mainWindow.screenshot())
        screenshot.name = "Options-lab-synthetic-result"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(mainWindow.buttons["pageInvestments"].exists)
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template)
        researchTab("已保存")
        let openSaved = mainWindow.buttons["optionLabSavedOpen"].firstMatch
        XCTAssertTrue(openSaved.waitForExistence(timeout: 10)); waitEnabled(openSaved); openSaved.click()
        waitText("已按完整输入重算", in: status)
        XCTAssertFalse(saveSnapshot.exists) // Saving is available only from the input page.
        let copy = mainWindow.buttons["optionLabCopy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.click()
        // Copy already clears the saved result. Recalculate first so editing,
        // rather than the copy action, must invalidate an available result.
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("结果"); waitText("SYNTHETIC", in: status)
        researchTab("输入")
        let symbol = mainWindow.textFields["optionLabSymbol"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 5)); symbol.click()
        symbol.typeKey("a", modifierFlags: .command); symbol.typeText("OTHER")
        waitEnabled(saveSnapshot, false)
        researchTab("结果")
        XCTAssertFalse(status.exists)
        // This path never opens a system file importer/exporter or real account.
    }

    func testOptionPricingExplicitAssumptionsReplayAndEditInvalidation() {
        configure(); launchMainWindow()
        XCTAssertTrue(app.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        let template = mainWindow.buttons["optionLabTemplate"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template); revealOptionControl(template); template.click()
        let assumptions = mainWindow.buttons["optionLabPricingSynthetic"]
        expandDisclosure("optionLabQuoteDetails", revealing: mainWindow.buttons["optionLabPricingDetails"])
        expandDisclosure("optionLabPricingDetails", revealing: assumptions)
        XCTAssertTrue(assumptions.waitForExistence(timeout: 5))
        revealOptionControl(assumptions); assumptions.click()
        let calculate = mainWindow.buttons["optionLabCalculate"]
        let saveSnapshot = mainWindow.buttons["optionLabSave"]
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("模型分析")
        let status = mainWindow.staticTexts["optionLabPricingStatus"]
        waitText("SYNTHETIC", in: status)
        waitText("RISK_NEUTRAL", in: mainWindow.staticTexts["optionLabRiskNeutralBoundary"])
        let localIV = mainWindow.staticTexts["optionLabIVState-SYNTHETIC-P100"]
        XCTAssertTrue(localIV.waitForExistence(timeout: 10)); waitText("可用", in: localIV)
        let screenshot = XCTAttachment(screenshot: mainWindow.screenshot())
        screenshot.name = "Options-pricing-synthetic-model-reference"; screenshot.lifetime = .keepAlways
        add(screenshot)
        saveOptionDraftFromInput()
        researchTab("模型分析"); waitText("已按完整输入重算", in: status)
        app.typeKey("1", modifierFlags: .command); app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template)
        researchTab("已保存")
        let openSaved = mainWindow.buttons["optionLabSavedOpen"].firstMatch
        XCTAssertTrue(openSaved.waitForExistence(timeout: 10)); waitEnabled(openSaved); revealOptionControl(openSaved); openSaved.click()
        waitText("已按完整输入重算", in: mainWindow.staticTexts["optionLabReportStatus"])
        researchTab("模型分析"); waitText("已按完整输入重算", in: status)
        XCTAssertFalse(saveSnapshot.exists)
        let copy = mainWindow.buttons["optionLabCopy"]
        revealOptionControl(copy); copy.click()
        // Editing must invalidate a freshly computed result, not an already-cleared copy.
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("模型分析"); waitText("SYNTHETIC", in: status)
        researchTab("输入")
        let rate = mainWindow.textFields["optionLabPricingRate"]
        expandDisclosure("optionLabQuoteDetails", revealing: mainWindow.buttons["optionLabPricingDetails"])
        // copyToDraft restores this report's enabled pricing disclosure. Do not
        // toggle it based on a lazy rate field that is merely below the viewport.
        // Section identity resets the outer viewport, but the field can still
        // lie below the initial visible input content.
        // The rate belongs to a LazyVGrid: on macOS 15 it may not enter the AX
        // tree until scrolled into view. Never locate the viewport through it.
        let editor = mainWindow.scrollViews.element(boundBy: 0)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let origin = mainWindow.staticTexts["optionLabOrigin"]
        func originFullyVisible() -> Bool {
            guard origin.exists else { return false }
            // This is a noninteractive top anchor, not a click target. At the
            // scroll limit it sits inside the content's 3-point padding; an
            // artificial 8-point inset would reject it even at scroll offset 0.
            let viewport = editor.frame.intersection(mainWindow.frame)
            return !origin.frame.isEmpty && !viewport.isEmpty
                && origin.frame.minY >= viewport.minY && origin.frame.maxY <= viewport.maxY
        }
        // Establish a known top anchor before searching downwards. Both loops
        // are bounded; missing controls remain failures rather than skips.
        for _ in 0..<30 where !originFullyVisible() { editor.scroll(byDeltaX: 0, deltaY: 160) }
        XCTAssertTrue(originFullyVisible(), "Missing input top anchor: \(mainWindow.debugDescription)")
        for _ in 0..<24 where !rate.exists { editor.scroll(byDeltaX: 0, deltaY: -80) }
        XCTAssertTrue(rate.waitForExistence(timeout: 5), "Missing rate after scrolling: \(mainWindow.debugDescription)")
        waitEnabled(rate)
        func rateFullyVisible() -> Bool {
            guard rate.exists else { return false }
            let viewport = editor.frame.intersection(mainWindow.frame).insetBy(dx: 0, dy: 8)
            return !rate.frame.isEmpty && !viewport.isEmpty && viewport.contains(rate.frame)
        }
        // isHittable can be true with only two visible points. Use bounded
        // pixel scrolling rather than a fast swipe that can overshoot the field.
        var lastScroll: CGFloat = 0
        var recoveringMissingRate = false
        for _ in 0..<10 {
            if rateFullyVisible() { break }
            if !rate.exists {
                // Recover an overshoot without asking an absent field for its frame.
                if !recoveringMissingRate { lastScroll = -lastScroll / 2 }
                recoveringMissingRate = true
                guard abs(lastScroll) >= 1 else { XCTFail("Rate field disappeared before scrolling"); return }
                editor.scroll(byDeltaX: 0, deltaY: lastScroll)
                continue
            }
            recoveringMissingRate = false
            let distance = editor.frame.midY - rate.frame.midY
            lastScroll = max(-80, min(80, distance))
            editor.scroll(byDeltaX: 0, deltaY: lastScroll)
        }
        guard rate.exists else { XCTFail("Rate field missing after bounded scrolling"); return }
        XCTAssertTrue(rateFullyVisible(), "Rate frame \(rate.frame), editor frame \(editor.frame)")
        XCTAssertTrue(rate.isHittable)
        rate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // XCUIElement.hasFocus is not available on macOS. Check the field's
        // own AX description, not a focused ancestor window or another field.
        let focused = NSPredicate { _, _ in
            rate.exists && rate.debugDescription.components(separatedBy: "\n").first?.contains("Keyboard Focused") == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 10),
                       .completed, rate.debugDescription)
        rate.typeKey("a", modifierFlags: .command); rate.typeText("0.04")
        XCTAssertEqual(rate.value as? String, "0.04")
        waitEnabled(saveSnapshot, false)
        researchTab("模型分析"); XCTAssertFalse(status.exists)
        // In-app synthetic controls only: no file panel, provider or Keychain.
    }

    func testOptionRiskScenarioExplicitEvidenceReplayAndInvalidation() {
        configure(); launchMainWindow()
        XCTAssertTrue(app.buttons["pageOptions"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        let template = mainWindow.buttons["optionLabTemplate"]
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template); revealOptionControl(template); template.click()
        let example = mainWindow.buttons["optionLabRiskScenarioSynthetic"]
        expandDisclosure("optionLabQuoteDetails", revealing: mainWindow.buttons["optionLabAdvancedAssumptions"])
        expandDisclosure("optionLabAdvancedAssumptions", revealing: example)
        XCTAssertTrue(example.waitForExistence(timeout: 5)); waitEnabled(example)
        revealOptionControl(example); example.click()
        let calculate = mainWindow.buttons["optionLabCalculate"], saveSnapshot = mainWindow.buttons["optionLabSave"]
        XCTAssertFalse(saveSnapshot.isEnabled)
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("风险与情景")
        let status = mainWindow.staticTexts["optionLabRiskScenarioStatus"]
        waitText("SYNTHETIC", in: status)
        waitText("Acceptable", in: mainWindow.staticTexts["optionLabLiquidityGrade"])
        waitText("已核对", in: mainWindow.staticTexts["optionLabEarningsState"])
        let riskShot = XCTAttachment(screenshot: mainWindow.screenshot())
        riskShot.name = "Options-offline-risk-synthetic-evidence"; riskShot.lifetime = .keepAlways; add(riskShot)
        // The matrix is an actual displayed price-major grid, not only a stored
        // input flag. Every one of the nine selected cells must expose a number.
        for spot in ["-0.1", "0", "0.1"] {
            for iv in ["-10", "0", "10"] {
                let cell = mainWindow.staticTexts["optionLabScenarioCell-" + spot + "-" + iv]
                XCTAssertTrue(cell.waitForExistence(timeout: 5))
                let displayed = (cell.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cell.label
                XCTAssertNotNil(Double(displayed), cell.debugDescription)
            }
        }
        waitText("INSTANTANEOUS", in: mainWindow.staticTexts["optionLabScenarioBoundary"])
        saveOptionDraftFromInput()
        researchTab("风险与情景"); waitText("已按完整输入重算", in: status)
        app.typeKey("1", modifierFlags: .command); app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(template.waitForExistence(timeout: 15)); waitEnabled(template)
        researchTab("已保存")
        let openSaved = mainWindow.buttons["optionLabSavedOpen"].firstMatch
        XCTAssertTrue(openSaved.waitForExistence(timeout: 10)); waitEnabled(openSaved); revealOptionControl(openSaved); openSaved.click()
        waitText("已按完整输入重算", in: mainWindow.staticTexts["optionLabReportStatus"])
        researchTab("风险与情景"); waitText("已按完整输入重算", in: status)
        XCTAssertFalse(saveSnapshot.exists)
        let copy = mainWindow.buttons["optionLabCopy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); revealOptionControl(copy); copy.click()
        waitEnabled(calculate); revealOptionControl(calculate); calculate.click()
        waitOptionInputSummary()
        researchTab("风险与情景"); waitText("SYNTHETIC", in: status)
        researchTab("输入")
        let symbol = mainWindow.textFields["optionLabSymbol"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 5)); revealOptionControl(symbol)
        symbol.click(); symbol.typeKey("a", modifierFlags: .command); symbol.typeText("OTHER")
        XCTAssertEqual(symbol.value as? String, "OTHER")
        waitEnabled(saveSnapshot, false)
        researchTab("风险与情景"); XCTAssertFalse(status.exists)
        XCTAssertFalse(mainWindow.staticTexts["optionLabScenarioCell-0-0"].exists)
        // No system file panel, network, real account, or Keychain is used.
    }

    func testResearchSnapshotInspectorAndReplay() {
        launchResearch()
        let save = app.buttons["researchSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); waitEnabled(save); save.click(); waitEnabled(save, false)
        researchTab("快照")
        let open = app.buttons["researchOpenSaved"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertTrue(app.staticTexts["researchCompany"].waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled)
        researchTab("原始数据")
        let filter = app.textFields["researchFieldFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.click(); filter.typeText("income.revenue")
        XCTAssertEqual(filter.value as? String, "income.revenue")
        let field = mainWindow.descendants(matching: .any)["researchFact-income.revenue"].firstMatch
        // The source rows are lazy and may be below the runner's smaller viewport.
        for _ in 0..<8 where !field.exists { mainWindow.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), mainWindow.debugDescription)
        waitText("income.revenue", in: field)
        researchTab("概览")
        let replay = app.buttons["researchReplay"]
        for _ in 0..<8 where !replay.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(replay.isHittable); replay.click()
        let message = app.staticTexts["researchMessage"]
        waitText("复算一致", in: message)
    }
    func testResearchMissingDataAndUserTargetsStayDistinct() {
        launchResearch(); app.buttons["researchGap"].click()
        let company = app.staticTexts["researchCompany"]
        waitText("GAP", in: company)
        researchTab("自选"); app.buttons["researchAddWatch"].click()
        let sheet = mainWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout:5))
        sheet.textFields["watchSymbol"].click(); sheet.textFields["watchSymbol"].typeText("ZZTEST")
        sheet.textFields["watchTarget"].click(); sheet.textFields["watchTarget"].typeText("12.50")
        sheet.buttons["watchSave"].click(); waitNoSheet(in:mainWindow)
        XCTAssertTrue(app.staticTexts["ZZTEST"].waitForExistence(timeout:5))
        app.buttons["查看研究"].click()
        XCTAssertTrue(app.staticTexts["暂无研究数据"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["researchScore"].exists)
    }
    func testResearchClearRequiresPreviewAndExplicitConfirmation() {
        launchResearch()
        let save = app.buttons["researchSave"]; waitEnabled(save); save.click(); waitEnabled(save,false)
        researchTab("备份")
        let preview = mainWindow.buttons["researchClearPreview"]
        for _ in 0..<10 where !preview.isHittable { mainWindow.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(preview.isHittable); preview.click()
        let panel = sheet(in:mainWindow)
        XCTAssertTrue(panel.waitForExistence(timeout:5))
        let commit = panel.buttons["researchTransferCommit"]
        XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return,modifierFlags:[])
        XCTAssertTrue(panel.exists)
        app.typeKey(.escape,modifierFlags:[]); waitNoSheet(in:mainWindow)
        researchTab("快照")
        XCTAssertTrue(mainWindow.buttons["researchOpenSaved"].firstMatch.waitForExistence(timeout:5))
        researchTab("备份")
        for _ in 0..<10 where !preview.isHittable { mainWindow.scrollViews.firstMatch.swipeUp() }
        preview.click(); XCTAssertTrue(panel.waitForExistence(timeout:5))
        let input = panel.textFields["researchTransferConfirmText"]
        input.click(); input.typeText("确认"); waitEnabled(commit)
        commit.click(); waitNoSheet(in:mainWindow)
        researchTab("快照")
        XCTAssertFalse(mainWindow.buttons["researchOpenSaved"].firstMatch.exists)
    }
    func testReturnDoesNotSaveAndTabSkipsDisabledControls() {
        launchSettings()
        let main = mainWindow
        firstSave()
        clickCredentialButton("credentialDelete", in: main)
        XCTAssertTrue(sheet(in: main).waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        waitNoSheet(in: main); waitEnabled(delete, false)
        let message = credentialMessage
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
        clickCredentialButton("credentialDelete", in: main)
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
        let failureMessage = credentialMessage
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
