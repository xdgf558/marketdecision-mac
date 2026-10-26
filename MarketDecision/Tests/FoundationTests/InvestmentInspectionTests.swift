import Foundation
import Testing
import PortfolioEngine
@testable import AppComposition

private actor InvestmentInspectionGate {
    private var arrived = false, released = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true; watchers.forEach { $0.resume() }; watchers.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func wait() async { if !arrived { await withCheckedContinuation { watchers.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor InvestmentInspectionProbe {
    private(set) var offMainThread = false
    private(set) var cancelled = false
    private(set) var accounts: [LedgerAccount] = []
    private(set) var events: [LedgerEvent] = []
    func record(offMainThread: Bool, accounts: [LedgerAccount], events: [LedgerEvent]) {
        self.offMainThread = offMainThread; self.accounts = accounts; self.events = events
    }
    func recordCancellation(_ value: Bool) { cancelled = value }
}

private enum InvestmentInspectionFailure: Error { case rejected }

// Sample the synchronous worker entry before its first suspension; this is not
// an assertion that a task keeps the same thread after an await.
private func investmentInspectionIsMainThread() -> Bool { Thread.isMainThread }

@Suite("Investment preparation worker lifecycle") @MainActor
struct InvestmentInspectionTests {
    private func baseline() -> PortfolioPreparationBaseline {
        .init(ledgerRevision: UUID(), performanceRevision: UUID(), inputEpoch: UUID())
    }
    private func draft(_ account: String = "ordinary-account") throws -> InvestmentCalculationDraft {
        try .init(accountID: account)
    }

    @Test func workerReceivesValueSnapshotsOffMainThreadAndReturnsOriginalBinding() async throws {
        let gate = InvestmentInspectionGate(), probe = InvestmentInspectionProbe()
        let source = try draft(), expectedBaseline = baseline()
        let accounts = [LedgerAccount(id: source.accountID, name: "Local account")]
        let model = InvestmentInspectionModel { input, accounts, events in
            let offMainThread = !investmentInspectionIsMainThread()
            await probe.record(offMainThread: offMainThread, accounts: accounts, events: events)
            await gate.hold()
            var output = input; output.startDay = "2026-01-02"
            return .init(draft: output, rows: [])
        }
        let pending = Task { await model.inspect(draft: source, baseline: expectedBaseline, accounts: accounts, events: []) }
        await gate.wait()
        #expect(model.isBusy && model.message == nil)
        await gate.release()
        let result = try #require(await pending.value)
        #expect(await probe.offMainThread)
        #expect(await probe.accounts == accounts)
        #expect(await probe.events.isEmpty)
        #expect(result.sourceDraft == source && result.baseline == expectedBaseline)
        #expect(result.draft.startDay == "2026-01-02" && result.rows.isEmpty)
        #expect(source.startDay.isEmpty)
        #expect(!model.isBusy && model.message == nil)
    }

    @Test func editAwayAndBackCannotReviveAnOlderInspectionOrReleaseNewBusyState() async throws {
        let oldGate = InvestmentInspectionGate(), newGate = InvestmentInspectionGate()
        let source = try draft(), expectedBaseline = baseline()
        let sequence = InvestmentInspectionSequence()
        let model = InvestmentInspectionModel { input, _, _ in
            let number = await sequence.next()
            if number == 1 { await oldGate.hold() } else { await newGate.hold() }
            return .init(draft: input, rows: [])
        }
        let old = Task { await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) }
        await oldGate.wait()
        // Editing A -> B -> A still invalidates, despite equal final values.
        model.invalidate(); model.invalidate()
        let current = Task { await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) }
        await newGate.wait()
        await oldGate.release()
        #expect(await old.value == nil)
        #expect(model.isBusy && model.message == nil)
        await newGate.release()
        #expect(await current.value?.sourceDraft == source)
        #expect(!model.isBusy)
    }

    @Test func leavingOrChangingContextDropsLateSuccessAndFailure() async throws {
        for fails in [false, true] {
            let gate = InvestmentInspectionGate(), source = try draft(), expectedBaseline = baseline()
            let model = InvestmentInspectionModel { input, _, _ in
                await gate.hold()
                if fails { throw InvestmentInspectionFailure.rejected }
                return .init(draft: input, rows: [])
            }
            let pending = Task { await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) }
            await gate.wait()
            model.invalidate()
            #expect(!model.isBusy && model.message == nil)
            await gate.release()
            #expect(await pending.value == nil)
            #expect(!model.isBusy && model.message == nil)
        }
    }

    @Test func callerCancellationReachesWorkerAndNeverPublishesCancellationAsError() async throws {
        let gate = InvestmentInspectionGate(), probe = InvestmentInspectionProbe()
        let source = try draft(), expectedBaseline = baseline()
        let model = InvestmentInspectionModel { input, _, _ in
            await gate.hold()
            await probe.recordCancellation(Task.isCancelled)
            return .init(draft: input, rows: [])
        }
        let pending = Task { await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) }
        await gate.wait()
        pending.cancel()
        await gate.release()
        #expect(await pending.value == nil)
        #expect(await probe.cancelled)
        #expect(!model.isBusy && model.message == nil)
    }

    @Test func oldFailureCannotOverwriteNewRequestOrClearItsBusyState() async throws {
        let oldGate = InvestmentInspectionGate(), currentGate = InvestmentInspectionGate()
        let source = try draft(), nextSource = try draft("other-account")
        let originalBaseline = baseline(), nextBaseline = baseline()
        let model = InvestmentInspectionModel { input, _, _ in
            if input.accountID == source.accountID {
                await oldGate.hold(); throw InvestmentInspectionFailure.rejected
            }
            await currentGate.hold()
            return .init(draft: input, rows: [])
        }
        let old = Task { await model.inspect(draft: source, baseline: originalBaseline, accounts: [], events: []) }
        await oldGate.wait()
        let current = Task { await model.inspect(draft: nextSource, baseline: nextBaseline, accounts: [], events: []) }
        await currentGate.wait()
        await oldGate.release()
        #expect(await old.value == nil)
        #expect(model.isBusy && model.message == nil)
        await currentGate.release()
        let result = try #require(await current.value)
        #expect(result.sourceDraft == nextSource && result.baseline == nextBaseline)
        #expect(!model.isBusy && model.message == nil)
    }

    @Test func currentFailureUsesFixedMessageAndNextRequestClearsIt() async throws {
        let source = try draft(), expectedBaseline = baseline(), sequence = InvestmentInspectionSequence()
        let model = InvestmentInspectionModel { input, _, _ in
            if await sequence.next() == 1 { throw InvestmentInspectionFailure.rejected }
            return .init(draft: input, rows: [])
        }
        #expect(await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) == nil)
        #expect(!model.isBusy && model.message == "缺项整理未完成。请核对日历、估值时刻与账本记录；原始资料未被修改。")
        #expect(await model.inspect(draft: source, baseline: expectedBaseline, accounts: [], events: []) != nil)
        #expect(!model.isBusy && model.message == nil)
    }
}

private actor InvestmentInspectionSequence {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
