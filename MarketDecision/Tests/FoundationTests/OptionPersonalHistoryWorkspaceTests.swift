import Foundation
import Testing
import PortfolioEngine
import Persistence
@testable import AppComposition

private actor PersonalHistoryGate {
    private var entered = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; observer?.resume(); observer = nil
        guard !released else { return }
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}

private actor PersonalHistoryStorage: PerformanceStorage {
    private var current: PerformanceStoreContext
    private let values: [UUID: SavedPerformanceReport]
    private var gates: [UUID: PersonalHistoryGate] = [:]
    private var failures = Set<UUID>()
    private(set) var factoryCalls = 0
    private(set) var writeCalls = 0

    init(_ reports: [SavedPerformanceReport]) throws {
        values = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0) })
        var accounts: [LedgerAccount] = []
        for report in reports {
            for account in report.report.input.accounts where !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        }
        let revision = reports.first?.ledgerRevision ?? UUID()
        let state = try LedgerEngine.replay(accounts: accounts, events: [])
        current = .init(ledger: .init(revision: revision, accounts: accounts, events: [], state: state), revision: UUID())
    }
    func factory() -> any PerformanceStorage { factoryCalls += 1; return self }
    func context() -> PerformanceStoreContext { current }
    func reports(accountID: String) -> [PerformanceSummary] {
        values.values.filter { $0.report.input.request.accountID == accountID }.map { value in
            .init(id: value.id, accountID: accountID, createdAt: value.createdAt,
                startDate: value.report.input.request.calendar.tradingDays.first ?? "",
                endDate: value.report.input.request.calendar.tradingDays.last ?? "", dayCount: 1,
                ledgerRevision: value.ledgerRevision, inputHash: value.inputHash, reportHash: value.reportHash,
                engineVersion: value.report.engineVersion, isCurrentLedger: value.ledgerRevision == current.ledger.revision)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func open(id: UUID) async throws -> SavedPerformanceReport {
        if let gate = gates[id] { await gate.pause() }
        if failures.contains(id) { throw PerformanceStoreError.corruptedStorage }
        guard let value = values[id] else { throw PerformanceStoreError.notFound }
        // Intentionally ignores task cancellation to exercise publication ownership.
        return value
    }
    func gate(_ id: UUID, with gate: PersonalHistoryGate, fail: Bool = false) {
        gates[id] = gate
        if fail { failures.insert(id) }
    }
    func changeRevision(ledger: Bool) {
        current = .init(ledger: .init(revision: ledger ? UUID() : current.ledger.revision, accounts: current.ledger.accounts,
            events: current.ledger.events, state: current.ledger.state), revision: UUID())
    }
    func prepare(request: PerformanceRequest, rawRequest: Data?, expectedLedgerRevision: UUID,
                 expectedPerformanceRevision: UUID) throws -> PerformancePreview {
        writeCalls += 1; throw PerformanceStoreError.invalidInput
    }
    func commit(planID: UUID, expectedLedgerRevision: UUID, expectedPerformanceRevision: UUID) throws -> SavedPerformanceReport {
        writeCalls += 1; throw PerformanceStoreError.invalidPlan
    }
    func cancel(planID: UUID) { writeCalls += 1 }
}

@MainActor @Suite("Personal option history read ownership")
struct OptionPersonalHistoryWorkspaceTests {
    private func saved(account: String = "personal", count: Int = 1, synthetic: Bool = false) throws -> SavedPerformanceReport {
        let report = try OptionPersonalHistoryFixture().report(count: count, synthetic: synthetic, accountID: account)
        let id = UUID()
        return .init(id: id, createdAt: report.input.request.calculatedAt, report: report,
            inputHash: "input-" + id.uuidString, reportHash: "report-" + id.uuidString,
            ledgerRevision: report.input.ledgerRevision, isCurrentLedger: true, replayMatched: true)
    }

    @Test func constructionAndAppearanceDoNotOpenLedgerAndExplicitReadNeverWrites() async throws {
        let report = try saved(), storage = try PersonalHistoryStorage([report])
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear()
        #expect(await storage.factoryCalls == 0)
        #expect(!model.hasLoadedAccounts && !model.hasLoadedReports && model.result == nil)
        await model.loadAccounts()
        #expect(model.hasLoadedAccounts && !model.hasLoadedReports && model.selectedAccountID == nil)
        await model.selectAccount("personal")
        #expect(model.hasLoadedReports && model.result == nil)
        await model.openSelected(report.id)
        #expect(model.result?.reportID == report.id)
        #expect(model.result?.statistics.eligibleN == 1)
        #expect(model.result?.statistics.winRate.value == nil)
        #expect(await storage.writeCalls == 0)
    }

    @Test func emptyVerifiedHistoryIsDifferentFromUnreadAndRejectedSynthetic() async throws {
        let empty = try saved(count: 0), example = try saved(synthetic: true)
        let storage = try PersonalHistoryStorage([empty, example])
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        #expect(model.result == nil && !model.hasError)
        model.appear()
        await model.loadAccounts(); await model.selectAccount("personal"); await model.openSelected(empty.id)
        #expect(model.result?.statistics.displayN == 0 && !model.hasError)
        await model.openSelected(example.id)
        #expect(model.result == nil && model.hasError)
        #expect(model.message?.contains("合成") == true)
        #expect(await storage.writeCalls == 0)
    }

    @Test func lateSuccessCannotRestoreThePreviouslySelectedAccount() async throws {
        let first = try saved(account: "first"), second = try saved(account: "second")
        let storage = try PersonalHistoryStorage([first, second]), gate = PersonalHistoryGate()
        await storage.gate(first.id, with: gate)
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear()
        await model.loadAccounts(); await model.selectAccount("first")
        let old = Task { await model.openSelected(first.id) }
        await gate.waitUntilEntered()
        await model.selectAccount("second"); await model.openSelected(second.id)
        #expect(model.result?.reportID == second.id)
        await gate.release(); await old.value
        #expect(model.selectedAccountID == "second" && model.result?.reportID == second.id)
        #expect(!model.isBusy && !model.hasError)
    }

    @Test func lateFailureCannotReplaceNewReportOrMessage() async throws {
        let first = try saved(), second = try saved(count: 2)
        let storage = try PersonalHistoryStorage([first, second]), gate = PersonalHistoryGate()
        await storage.gate(first.id, with: gate, fail: true)
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear()
        await model.loadAccounts(); await model.selectAccount("personal")
        let old = Task { await model.openSelected(first.id) }
        await gate.waitUntilEntered()
        await model.openSelected(second.id)
        let message = model.message
        await gate.release(); await old.value
        #expect(model.result?.reportID == second.id && model.message == message && !model.hasError)
        #expect(!model.isBusy)
    }

    @Test(arguments: [false, true]) func revisionsChangingDuringOpenRejectPublication(_ ledger: Bool) async throws {
        let report = try saved(), storage = try PersonalHistoryStorage([report]), gate = PersonalHistoryGate()
        await storage.gate(report.id, with: gate)
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear()
        await model.loadAccounts(); await model.selectAccount("personal")
        let read = Task { await model.openSelected(report.id) }
        await gate.waitUntilEntered(); await storage.changeRevision(ledger: ledger); await gate.release(); await read.value
        #expect(model.result == nil && model.hasError && !model.isBusy)
        #expect(model.message?.contains("版本已变化") == true)
        #expect(model.summaries.isEmpty)
    }

    @Test func leavingAndRestoreDoNotPublishOrAutomaticallyReload() async throws {
        let report = try saved(), storage = try PersonalHistoryStorage([report]), gate = PersonalHistoryGate()
        await storage.gate(report.id, with: gate)
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear()
        await model.loadAccounts(); await model.selectAccount("personal")
        let read = Task { await model.openSelected(report.id) }
        await gate.waitUntilEntered()
        model.disappear()
        let calls = await storage.factoryCalls
        let transfer = UUID(); model.beginLedgerTransfer(transfer)
        #expect(!model.ledgerTransferRefreshNeeded)
        await model.refreshLedgerTransfer(transfer); model.endLedgerTransfer(transfer)
        await gate.release(); await read.value
        #expect(model.result == nil && model.accounts.isEmpty && !model.isBusy)
        #expect(await storage.factoryCalls == calls)
        #expect(await storage.writeCalls == 0)
    }

    @Test func queuedOrAlreadyCancelledLoadCannotReopenDisappearedHistory() async throws {
        let storage = try PersonalHistoryStorage([saved()])
        let model = OptionPersonalHistoryWorkspaceModel(storageFactory: { await storage.factory() })
        model.appear(); model.disappear()
        await model.loadAccounts()
        #expect(await storage.factoryCalls == 0)
        #expect(!model.hasLoadedAccounts && model.result == nil && !model.isBusy)

        model.appear()
        let gate = PersonalHistoryGate()
        let queued = Task { await gate.pause(); await model.loadAccounts() }
        await gate.waitUntilEntered(); queued.cancel(); await gate.release(); await queued.value
        #expect(await storage.factoryCalls == 0)
        #expect(!model.hasLoadedAccounts && model.result == nil && !model.isBusy)
    }
}
