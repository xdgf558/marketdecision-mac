import XCTest
import CryptoKit

/// Real system panels against the production app sources, Release configuration and
/// production file entitlements. A dedicated product and bundle ID isolate its SQLite
/// container. No UI_TEST_HOST, in-memory store, launch hooks, settings or Keychain calls.
@MainActor final class ProductionFilePanelTests: XCTestCase {
    private let acceptanceID = "local.marketdecision.file-acceptance"
    private var app: XCUIApplication!
    private var files: URL!
    private var window: XCUIElement {
        app.windows.containing(.button, identifier: "pageResearch").firstMatch
    }
    private var panel: XCUIElement { window.sheets.firstMatch }
    private var message: XCUIElement { window.staticTexts["researchTransferMessage"].firstMatch }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        // Keep only xcresult attachments; never delete any application container here.
        if let files { try? FileManager.default.removeItem(at: files) }
        files = nil
    }

    func testFileExportWritesMarkdownAndZIPAndCancelPreservesState() throws {
        try launchClean()
        try seedResearch()
        let baseline = try exportArchive("baseline.zip")
        XCTAssertEqual(baseline.roots.count, 1)
        XCTAssertEqual(baseline.objects.count, 6)
        XCTAssertEqual(baseline.watchlist.count, 1)

        let markdown = files.appendingPathComponent("DEMO-research.md")
        try export(button: "researchExportMarkdown", to: markdown)
        let bytes = try Data(contentsOf: markdown)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# DEMO 本地研究"))
        XCTAssertTrue(text.contains("合成 DEMO"))
        XCTAssertTrue(text.contains("不是可恢复备份"))
        XCTAssertTrue(text.contains("## 完整冻结输入与版本（合成证据）"))
        let frozenJSON = try XCTUnwrap(text.components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frozenJSON.utf8)) as? [String: Any])
        XCTAssertEqual(document["symbol"] as? String, "DEMO")
        attachFile(markdown, name: "exported-markdown")
        attachDigest(bytes, name: "markdown-sha256")

        tab("备份")
        click("researchExportBackup")
        XCTAssertTrue(panel.waitForExistence(timeout: 10), window.debugDescription)
        let cancelled = files.appendingPathComponent("cancelled.zip")
        setSaveDestination(cancelled)
        app.typeKey(.escape, modifierFlags: [])
        waitAbsent(panel)
        waitText("文件操作已取消", in: message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))

        click("researchImport")
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        waitAbsent(panel)
        waitText("文件操作已取消", in: message)
        let afterCancel = try exportArchive("after-cancel.zip")
        XCTAssertEqual(afterCancel.stateBytes, baseline.stateBytes)
    }

    func testFileImportRejectsCorruptionAndMergeKeepsConflict() throws {
        try launchClean()
        try seedResearch()
        let baseline = try exportArchive("baseline.zip")
        let damaged = files.appendingPathComponent("damaged.zip")
        var bytes = try Data(contentsOf: baseline.url)
        bytes.append(0) // Invalid trailing bytes, retaining the real .zip file type.
        try bytes.write(to: damaged)
        chooseImport(damaged, replace: false)
        waitText("恢复预检失败", in: message)
        XCTAssertFalse(panel.exists)
        XCTAssertEqual(try exportArchive("after-rejection.zip").stateBytes, baseline.stateBytes)

        tab("自选")
        let edit = window.buttons["编辑目标"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        replaceText(panel.textFields["watchTarget"], with: "15.75")
        panel.buttons["watchSave"].click(); waitAbsent(panel)
        let changed = try exportArchive("changed.zip")
        XCTAssertNotEqual(try userValues(changed.watchlist), try userValues(baseline.watchlist))

        chooseImport(baseline.url, replace: false)
        waitForPlan()
        waitText("自选冲突保留两份：FILETEST", in: panel)
        let commit = panel.buttons["researchTransferCommit"]
        XCTAssertFalse(commit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(panel.exists)
        app.typeKey(.escape, modifierFlags: []); waitAbsent(panel)
        XCTAssertEqual(try exportArchive("after-plan-cancel.zip").stateBytes, changed.stateBytes)

        chooseImport(baseline.url, replace: false)
        waitForPlan(); commitPlan()
        let merged = try exportArchive("merged.zip")
        XCTAssertEqual(merged.roots.count, 1)
        XCTAssertEqual(merged.objects.count, 6)
        XCTAssertEqual(merged.conflicts.count, 1)
        XCTAssertEqual(try graphBytes(merged), try graphBytes(baseline))
        XCTAssertEqual(try userValues(merged.watchlist), try userValues(changed.watchlist))
        XCTAssertEqual(try userValues(merged.conflicts), try userValues(baseline.watchlist))
    }

    func testReplaceAndClearPersistAcrossRelaunch() throws {
        try launchClean()
        try seedResearch()
        let baseline = try exportArchive("baseline.zip")
        // Build a visibly different target exclusively in the isolated app container.
        clearBusiness()
        addWatch(symbol: "OTHER", target: "99")
        let before = try exportArchive("before-replace.zip")
        XCTAssertTrue(before.roots.isEmpty)
        XCTAssertEqual(before.watchlist.first?["symbol"] as? String, "OTHER")

        chooseImport(baseline.url, replace: true)
        waitForPlan()
        waitText("覆盖当前", in: panel)
        commitPlan()
        let restored = try exportArchive("restored.zip")
        XCTAssertEqual(try graphBytes(restored), try graphBytes(baseline))
        XCTAssertEqual(try userValues(restored.watchlist), try userValues(baseline.watchlist))
        XCTAssertNotEqual(restored.watchlist.first?["revision"] as? String, baseline.watchlist.first?["revision"] as? String)
        XCTAssertTrue(restored.conflicts.isEmpty)

        app.terminate(); app.launch(); openResearch()
        tab("快照")
        let open = window.buttons["researchOpenSaved"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15)); open.click()
        XCTAssertTrue(window.staticTexts["researchCompany"].waitForExistence(timeout: 15))
        XCTAssertFalse(window.buttons["researchSave"].isEnabled)
        click("researchReplay")
        waitText("复算一致", in: window.staticTexts["researchMessage"])
        XCTAssertEqual(try exportArchive("after-relaunch.zip").stateBytes, restored.stateBytes)

        tab("备份"); click("researchClearPreview"); waitForPlan()
        XCTAssertFalse(panel.buttons["researchTransferCommit"].isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(panel.exists)
        app.typeKey(.escape, modifierFlags: []); waitAbsent(panel)
        XCTAssertEqual(try exportArchive("after-clear-cancel.zip").stateBytes, restored.stateBytes)
        clearBusiness()
        let empty = try exportArchive("cleared.zip")
        XCTAssertTrue(empty.roots.isEmpty && empty.objects.isEmpty && empty.watchlist.isEmpty && empty.conflicts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseline.url.path))
        app.terminate(); app.launch(); openResearch()
        tab("快照")
        XCTAssertFalse(window.buttons["researchOpenSaved"].firstMatch.exists)
        tab("自选")
        XCTAssertFalse(window.staticTexts["FILETEST"].exists)
        XCTAssertEqual(try exportArchive("cleared-after-relaunch.zip").stateBytes, empty.stateBytes)
    }

    private func launchClean() throws {
        continueAfterFailure = false
        let url = try acceptanceAppURL()
        let info = try XCTUnwrap(NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, acceptanceID,
                       "Never run destructive acceptance against the user's application bundle.")
        let signature = try run("/usr/bin/codesign", ["-d", "--entitlements", ":-", url.path])
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: signature, format: nil) as? [String: Any])
        XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write"])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        let signatureEvidence = XCTAttachment(data: signature, uniformTypeIdentifier: "com.apple.property-list")
        signatureEvidence.name = "effective-production-file-permissions"; signatureEvidence.lifetime = .keepAlways
        add(signatureEvidence)
        files = FileManager.default.temporaryDirectory.appendingPathComponent("MarketDecisionFilePanel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        app = XCUIApplication(url: url)
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-appearance", "light"]
        app.launch(); openResearch()
        clearBusiness()
    }

    private func acceptanceAppURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["MARKETDECISION_FILE_ACCEPTANCE_APP"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var directory = Bundle(for: ProductionFilePanelTests.self).bundleURL
        for _ in 0..<8 {
            let app = directory.appendingPathComponent("MarketDecisionFileAcceptance.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: app.path) { return app }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "FilePanelAcceptance", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Build the ProductionFilePanelTests scheme or supply MARKETDECISION_FILE_ACCEPTANCE_APP."])
    }

    private func openResearch() {
        let button = app.buttons["pageResearch"]
        XCTAssertTrue(button.waitForExistence(timeout: 20)); button.click()
        XCTAssertTrue(window.staticTexts["researchCompany"].waitForExistence(timeout: 20), window.debugDescription)
    }
    private func seedResearch() throws {
        tab("概览"); click("researchDemo")
        let save = window.buttons["researchSave"]
        waitEnabled(save, true); save.click(); waitEnabled(save, false)
        addWatch(symbol: "FILETEST", target: "12.50")
    }
    private func addWatch(symbol: String, target: String) {
        tab("自选"); click("researchAddWatch")
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        panel.textFields["watchSymbol"].click(); panel.textFields["watchSymbol"].typeText(symbol)
        panel.textFields["watchTarget"].click(); panel.textFields["watchTarget"].typeText(target)
        panel.buttons["watchSave"].click(); waitAbsent(panel)
        XCTAssertTrue(window.staticTexts[symbol].waitForExistence(timeout: 10))
    }
    private func tab(_ title: String) {
        let radio = window.radioButtons[title]
        if radio.exists { radio.click() }
        else {
            let button = window.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 10), window.debugDescription); button.click()
        }
    }
    private func click(_ identifier: String) {
        let button = window.buttons[identifier]
        for _ in 0..<12 where !button.isHittable { window.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isHittable, window.debugDescription)
        waitEnabled(button, true); button.click()
    }
    private func clearBusiness() {
        tab("备份"); click("researchClearPreview"); waitForPlan(); commitPlan()
    }
    private func waitForPlan() {
        XCTAssertTrue(panel.textFields["researchTransferConfirmText"].waitForExistence(timeout: 20), window.debugDescription)
    }
    private func commitPlan() {
        let confirm = panel.textFields["researchTransferConfirmText"]
        confirm.click(); confirm.typeText("确认")
        let commit = panel.buttons["researchTransferCommit"]
        waitEnabled(commit, true); commit.click(); waitAbsent(panel)
        waitText("操作已提交", in: message)
    }
    private func chooseImport(_ url: URL, replace: Bool) {
        tab("备份")
        let option = window.radioButtons[replace ? "覆盖 · 替换研究与自选" : "合并 · 冲突保留两份"]
        XCTAssertTrue(option.waitForExistence(timeout: 10)); option.click()
        click("researchImport")
        XCTAssertTrue(panel.waitForExistence(timeout: 10), window.debugDescription)
        goTo(url)
        let open = panel.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "打开", "Open")).firstMatch
        waitEnabled(open, true); open.click()
    }
    private func export(button: String, to url: URL) throws {
        tab("备份"); click(button)
        XCTAssertTrue(panel.waitForExistence(timeout: 15), window.debugDescription)
        setSaveDestination(url)
        let save = panel.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "存储", "Save")).firstMatch
        waitEnabled(save, true); save.click(); waitAbsent(panel)
        waitText("文件已导出", in: message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Export must create the selected external file: " + url.path)
    }
    private func setSaveDestination(_ url: URL) {
        goTo(url.deletingLastPathComponent())
        // The standard save panel exposes the filename as its editable text field;
        // search fields and tag combo boxes have different accessibility roles.
        let fields = panel.textFields.allElementsBoundByIndex.filter { $0.isHittable && $0.isEnabled }
        XCTAssertEqual(fields.count, 1, panel.debugDescription)
        guard let filename = fields.first else { return }
        replaceText(filename, with: url.lastPathComponent)
    }
    private func goTo(_ url: URL) {
        // Use the system Go to Folder shortcut, not OS-version-specific AX IDs.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
    }
    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.click()
        app.typeKey("a", modifierFlags: .command); field.typeText(text)
    }
    private func waitEnabled(_ element: XCUIElement, _ enabled: Bool) {
        let predicate = NSPredicate(format: "exists == true AND enabled == %@", NSNumber(value: enabled))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 20), .completed, element.debugDescription)
    }
    private func waitAbsent(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 20), .completed, window.debugDescription)
    }
    private func waitText(_ text: String, in element: XCUIElement) {
        let predicate = NSPredicate { _, _ in
            guard element.exists else { return false }
            if element.label.contains(text) || (element.value as? String)?.contains(text) == true { return true }
            return element.staticTexts.allElementsBoundByIndex.contains {
                $0.label.contains(text) || ($0.value as? String)?.contains(text) == true
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 20), .completed, element.debugDescription)
    }

    private struct Archive {
        let url: URL
        let stateBytes: Data
        let objects: [[String: Any]]
        let roots: [[String: Any]]
        let watchlist: [[String: Any]]
        let conflicts: [[String: Any]]
    }
    private func exportArchive(_ filename: String) throws -> Archive {
        let url = files.appendingPathComponent(filename)
        try export(button: "researchExportBackup", to: url)
        // Independent system ZIP decoding and CryptoKit hash verification; this
        // test target does not link the production codec or persistence package.
        _ = try run("/usr/bin/unzip", ["-t", url.path])
        let entries = String(decoding: try run("/usr/bin/unzip", ["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(entries.sorted(), ["manifest.json", "research-state.json"])
        let manifestData = try run("/usr/bin/unzip", ["-p", url.path, "manifest.json"])
        let stateData = try run("/usr/bin/unzip", ["-p", url.path, "research-state.json"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        XCTAssertEqual(manifest["format"] as? String, "research-backup.v1")
        XCTAssertEqual(manifest["scope"] as? String, "synthetic-research-and-watchlist")
        XCTAssertEqual(manifest["sha256"] as? String, sha256(stateData))
        XCTAssertEqual(manifest["size"] as? Int, stateData.count)
        XCTAssertEqual(state["format"] as? String, "research-state.v1")
        let archive = Archive(url: url, stateBytes: stateData,
                              objects: try XCTUnwrap(state["objects"] as? [[String: Any]]),
                              roots: try XCTUnwrap(state["roots"] as? [[String: Any]]),
                              watchlist: try XCTUnwrap(state["watchlist"] as? [[String: Any]]),
                              conflicts: try XCTUnwrap(state["conflicts"] as? [[String: Any]]))
        for (key, count) in [("objects", archive.objects.count), ("roots", archive.roots.count), ("watchlist", archive.watchlist.count), ("conflicts", archive.conflicts.count)] {
            XCTAssertEqual(manifest[key] as? Int, count)
        }
        attachFile(url, name: filename)
        attachDigest(try Data(contentsOf: url), name: filename + "-sha256")
        return archive
    }
    private func graphBytes(_ archive: Archive) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["objects": archive.objects, "roots": archive.roots], options: .sortedKeys)
    }
    private func userValues(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries.map { entry in
            var values = entry; values.removeValue(forKey: "revision"); return values
        }, options: .sortedKeys)
    }
    private func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        return data
    }
    private func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func attachFile(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func attachDigest(_ bytes: Data, name: String) {
        let attachment = XCTAttachment(string: sha256(bytes)); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
