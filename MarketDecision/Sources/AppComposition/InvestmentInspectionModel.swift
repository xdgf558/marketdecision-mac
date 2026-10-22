import Foundation
import Observation
import PortfolioEngine

/// The editable additions and the one historical-position inspection that made
/// them. Neither recorded rows nor this result grant pricing/data eligibility.
public struct InvestmentInspectionOutput: Equatable, Sendable {
    public let draft: InvestmentCalculationDraft
    public let rows: [InvestmentDayRequirement]
    public init(draft: InvestmentCalculationDraft, rows: [InvestmentDayRequirement]) {
        self.draft = draft; self.rows = rows
    }
}

/// The view must also compare sourceDraft, account and baseline with its current
/// inputs before publishing. The coordinator's operation ID additionally prevents
/// an A -> B -> A edit or leave/reopen cycle from reviving an older inspection.
public struct InvestmentInspectionResult: Equatable, Sendable {
    public let sourceDraft: InvestmentCalculationDraft
    public let baseline: PortfolioPreparationBaseline
    public let draft: InvestmentCalculationDraft
    public let rows: [InvestmentDayRequirement]
}

/// Owns only preparation work, never storage or approval. Cancelling suppresses
/// publication and requests cooperative cancellation; a running synchronous
/// ledger replay is not promised to stop immediately.
@MainActor @Observable public final class InvestmentInspectionModel {
    public private(set) var isBusy = false
    public private(set) var message: String?
    @ObservationIgnored private let worker: Worker
    @ObservationIgnored private var work: Task<InvestmentInspectionOutput, any Error>?
    @ObservationIgnored private var operation: UUID?

    typealias Worker = @Sendable (InvestmentCalculationDraft, [LedgerAccount], [LedgerEvent]) async throws -> InvestmentInspectionOutput

    public init() { worker = Self.arrange }
    // A deterministic worker seam for lifecycle tests, not an application API.
    init(worker: @escaping Worker) { self.worker = worker }

    public func invalidate() {
        operation = nil
        work?.cancel(); work = nil
        isBusy = false; message = nil
    }

    public func inspect(draft: InvestmentCalculationDraft, baseline: PortfolioPreparationBaseline,
                        accounts: [LedgerAccount], events: [LedgerEvent]) async -> InvestmentInspectionResult? {
        guard !Task.isCancelled else { return nil }
        invalidate()
        let id = UUID(), worker = self.worker
        operation = id; isBusy = true
        // All arguments are immutable Sendable value snapshots. In particular,
        // no Observable model or SwiftUI binding is captured by the worker.
        let pending = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try await worker(draft, accounts, events)
            try Task.checkCancellation()
            return output
        }
        work = pending
        defer {
            // Old completion must never release a newer request's busy state.
            if operation == id { operation = nil; work = nil; isBusy = false }
        }
        do {
            let output = try await withTaskCancellationHandler(operation: {
                try await pending.value
            }, onCancel: { pending.cancel() })
            guard operation == id, !Task.isCancelled else { return nil }
            return .init(sourceDraft: draft, baseline: baseline, draft: output.draft, rows: output.rows)
        } catch {
            guard operation == id, !Task.isCancelled, !(error is CancellationError) else { return nil }
            message = "缺项整理未完成。请核对日历、估值时刻与账本记录；原始资料未被修改。"
            return nil
        }
    }

    nonisolated private static func arrange(_ draft: InvestmentCalculationDraft, _ accounts: [LedgerAccount],
                                           _ events: [LedgerEvent]) async throws -> InvestmentInspectionOutput {
        try Task.checkCancellation()
        var prepared = draft
        // fillMissingQuotes returns the requirements it already evaluated. Do
        // not run requirements again merely to build the view's status rows.
        let rows = try prepared.fillMissingQuotes(accounts: accounts, events: events)
        try Task.checkCancellation()
        return .init(draft: prepared, rows: rows)
    }
}
