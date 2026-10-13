import Foundation
import Observation
import CoreDomain
import PortfolioEngine
import Persistence

/// One page owns one preview. Storage owns the transaction and checks the exact
/// revision captured before parsing, replay or an asynchronous confirmation.
@MainActor @Observable public final class LedgerWorkspaceModel: LedgerTransferParticipant {
    public private(set) var snapshot: LedgerSnapshot?
    public private(set) var preview: LedgerImportPreview?
    public private(set) var message: String?
    public private(set) var hasError = false
    public private(set) var isBusy = false
    public private(set) var selectedAccountID: String?
    private let storage: any LedgerStorage
    public private(set) var transfer: LedgerTransferModel?
    public private(set) var transferEpoch = UUID()
    private var transferOperation: UUID?
    private var transferRefreshedGeneration: UUID?
    private var generation = UUID()
    private var visible = true
    private var operation: UUID?
    private var committing: UUID?

    public init(storage: any LedgerStorage) { self.storage = storage }
    public func installTransfer(_ transfer: LedgerTransferModel, coordinator: LedgerTransferCoordinator) {
        self.transfer = transfer; coordinator.register(self)
    }
    var ledgerTransferRefreshNeeded: Bool {
        transferOperation != nil && visible && committing == nil && transferRefreshedGeneration != generation
    }
    func beginLedgerTransfer(_ id: UUID) {
        transferOperation = id; transferEpoch = UUID(); transferRefreshedGeneration = nil
        generation = UUID(); operation = nil; isBusy = true
        let previous = takePreview()
        snapshot = nil; message = nil; hasError = false
        if let previous, committing == nil { Task { [storage] in await storage.cancel(planID: previous.id) } }
    }
    func refreshLedgerTransfer(_ id: UUID) async {
        guard transferOperation == id, visible, committing == nil else { return }
        let token = begin()
        await readSnapshot(token: token)
        if owns(token) { transferRefreshedGeneration = generation }
        finish(token)
    }
    func endLedgerTransfer(_ id: UUID) {
        guard transferOperation == id else { return }
        transferOperation = nil; transferRefreshedGeneration = nil
        isBusy = committing != nil || operation != nil
    }
    public var canPrepare: Bool { !isBusy && snapshot != nil && selectedAccountID != nil }
    public var canConfirm: Bool { !isBusy && preview?.canCommit == true }

    public func load() async {
        visible = true
        guard !isBusy else { return }
        let oldPlan = takePreview(), token = begin()
        snapshot = nil
        defer { finish(token) }
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
        guard owns(token) else { return }
        await readSnapshot(token: token)
    }

    public func chooseAccount(_ id: String) async {
        guard !isBusy, snapshot?.accounts.contains(where: { $0.id == id }) == true else { return }
        let oldPlan = takePreview()
        generation = UUID()
        selectedAccountID = id; message = nil; hasError = false
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
    }

    public func createAccount(_ account: LedgerAccount) async {
        guard !isBusy, let revision = snapshot?.revision else { return }
        let oldPlan = takePreview(), token = begin()
        defer { finish(token) }
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
        guard owns(token), !Task.isCancelled else { return }
        do {
            _ = try await storage.createAccount(account, expectedRevision: revision)
            guard owns(token) else { return }
            await readSnapshot(token: token)
            guard owns(token) else { return }
            if !hasError {
                selectedAccountID = account.id
                message = "本地 USD 账户已建立。现金与持仓由明确交易重放，不读取券商账户。"
            }
        } catch {
            guard owns(token) else { return }
            hasError = true; message = "账户未建立。请核对标识、名称及当前账本版本，再重新载入。"
        }
    }

    public func prepareManual(events: [LedgerEvent]) async {
        guard canPrepare, let revision = snapshot?.revision, let accountID = selectedAccountID else { return }
        guard !events.isEmpty, events.allSatisfy({ $0.accountID == accountID }) else {
            rejectAccountMismatch(); return
        }
        await prepare { [storage] in
            try await storage.previewManual(events: events, expectedRevision: revision)
        }
    }

    public func prepareCSV(_ data: Data, sourceSystem: String, mapping: LedgerCSVMapping, excludedRows: Set<Int> = []) async {
        guard canPrepare, let revision = snapshot?.revision, let accountID = selectedAccountID else { return }
        await prepare { [storage] in
            try await storage.previewCSV(data: data, accountID: accountID, sourceSystem: sourceSystem,
                                         mapping: mapping, excludedRows: excludedRows, expectedRevision: revision)
        }
    }

    public func readSelectedCSV(_ url: URL) async -> Data? {
        guard !isBusy else { return nil }
        let oldPlan = takePreview(), token = begin()
        defer { finish(token) }
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
        guard owns(token), !Task.isCancelled else { return nil }
        do {
            let data = try await ResearchSelectedFile.read(url, maximumBytes: LedgerCSV.maximumBytes)
            guard owns(token), !Task.isCancelled else { return nil }
            _ = try LedgerCSV.parse(data)
            guard String(data: data, encoding: .utf8) != nil else { throw LedgerCSVError.invalidUTF8 }
            message = "CSV 已读取，尚未入账。请明确映射并预览。"
            return data
        } catch {
            guard owns(token) else { return nil }
            hasError = !Task.isCancelled
            message = Task.isCancelled ? "CSV 读取已取消，未写入账本。"
                : "所选 CSV 无法读取或不符合格式与大小限制；未写入账本。"
            return nil
        }
    }

    public func prepareCorrection(originalEventID: String, replacement: LedgerEvent) async {
        guard canPrepare, let revision = snapshot?.revision, let accountID = selectedAccountID else { return }
        guard replacement.accountID == accountID,
              snapshot?.events.contains(where: { $0.id == originalEventID && $0.accountID == accountID }) == true else {
            rejectAccountMismatch(); return
        }
        await prepare { [storage] in
            try await storage.previewCorrection(originalEventID: originalEventID,
                                                 replacement: replacement, reason: replacement.source.evidence, expectedRevision: revision)
        }
    }

    public func prepareBatchReversal(batchID: String, timestamp: String, reason: String) async {
        guard canPrepare, let snapshot, let accountID = selectedAccountID else { return }
        guard let batch = snapshot.batches.first(where: { $0.id == batchID }), !batch.newEventIDs.isEmpty,
              batch.newEventIDs.allSatisfy({ id in snapshot.events.contains { $0.id == id && $0.accountID == accountID } }) else {
            rejectAccountMismatch(); return
        }
        let revision = snapshot.revision
        do {
            let date = try LedgerCSV.timestamp(timestamp)
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalidEvidence }
            await prepare { [storage] in
                try await storage.previewBatchReversal(batchID: batchID, effectiveAt: date, reason: reason, expectedRevision: revision)
            }
        } catch {
            hasError = true; message = "批次冲销未预检，请填写带时区的生效时刻与真实原因。"
        }
    }

    /// Editing the original draft invalidates approval. A new preview is required;
    /// no old row can silently inherit the revised form or a newer store baseline.
    public func draftChanged() {
        guard committing == nil, transferOperation == nil else { return }
        generation = UUID(); operation = nil; isBusy = false
        let oldPlan = takePreview()
        message = nil; hasError = false
        if let oldPlan { Task { [storage] in await storage.cancel(planID: oldPlan.id) } }
    }

    @discardableResult public func confirm(id: UUID, expectedRevision: UUID) async -> Bool {
        guard canConfirm, let plan = preview, plan.id == id,
              plan.targetRevision == expectedRevision else { return false }
        let token = begin(), commit = UUID()
        committing = commit
        do {
            let result = try await storage.commit(planID: id, expectedRevision: expectedRevision)
            if owns(token) {
                snapshot = result; preview = nil
                reconcileSelection()
                message = "批次已完整入账；现金、持仓与来源审计已重放。这里不生成市值或收益率。"
                hasError = false
            }
            await finishCommit(token: token, commit: commit)
            return true
        } catch {
            if owns(token) {
                hasError = true
                if isStale(error) {
                    preview = nil
                    await storage.cancel(planID: id)
                    if owns(token) { message = "账本已变化，原计划已失效；请重新载入并预览，未自动替换批准基线。" }
                } else {
                    message = "批次未提交；原预览与版本保留，可重试或取消。不会留下半个批次。"
                }
            } else {
                // This releases a process-local plan only. It never undoes a transaction.
                await storage.cancel(planID: id)
            }
            await finishCommit(token: token, commit: commit)
            return false
        }
    }

    public func cancelPreview() async {
        guard committing == nil, transferOperation == nil else { return }
        generation = UUID(); operation = nil; isBusy = false
        let oldPlan = takePreview()
        message = "预览已取消，未写入账本。"; hasError = false
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
    }

    public func disappear() {
        visible = false; generation = UUID(); operation = nil
        snapshot = nil; message = nil; hasError = false
        let oldPlan = takePreview()
        if committing == nil {
            isBusy = transferOperation != nil
            if let oldPlan { Task { [storage] in await storage.cancel(planID: oldPlan.id) } }
        }
    }

    private func prepare(_ work: @escaping @Sendable () async throws -> LedgerImportPreview) async {
        let oldPlan = takePreview(), token = begin()
        defer { finish(token) }
        if let oldPlan { await storage.cancel(planID: oldPlan.id) }
        guard owns(token), !Task.isCancelled else { return }
        do {
            let result = try await work()
            guard owns(token), !Task.isCancelled else {
                await storage.cancel(planID: result.id); return
            }
            preview = result
            hasError = !result.canCommit
            message = result.canCommit ? "预检完成。请核对新增与重复记录，再明确确认整批入账。"
                : "存在冲突或无效行，整批暂不提交。请修正原文或字段映射后重新预览；不会自动丢弃记录。"
        } catch {
            guard owns(token) else { return }
            hasError = true; message = "预检未完成。请核对字段、明确费用、交易来源和指定批次；缺少证据不会自动补零。"
        }
    }

    private func takePreview() -> LedgerImportPreview? {
        let previous = preview; preview = nil; return previous
    }
    private func begin() -> UUID {
        let id = UUID(); generation = id; operation = id
        isBusy = true; message = nil; hasError = false
        return id
    }
    private func owns(_ id: UUID) -> Bool { visible && generation == id && operation == id }
    private func finish(_ id: UUID) {
        guard operation == id else { return }
        operation = nil; isBusy = committing != nil || transferOperation != nil
    }
    private func finishCommit(token: UUID, commit: UUID) async {
        guard committing == commit else { return }
        committing = nil
        if transferOperation != nil { isBusy = true; return }
        if operation == token { finish(token) }
        else {
            isBusy = false
            // A page reopened during the transaction observes only a fresh read.
            // The previous session's result and error never become its message.
            if visible { await load() }
        }
    }
    private func readSnapshot(token: UUID) async {
        do {
            let result = try await storage.snapshot()
            guard owns(token), !Task.isCancelled else { return }
            snapshot = result; reconcileSelection()
        } catch {
            guard owns(token) else { return }
            snapshot = nil; hasError = true
            message = "账本读取或完整性检查失败，未显示旧余额。已有记录保留，可重新载入。"
        }
    }
    private func reconcileSelection() {
        if !((snapshot?.accounts ?? []).contains { $0.id == selectedAccountID }) {
            selectedAccountID = snapshot?.accounts.first?.id
        }
    }
    private func rejectAccountMismatch() {
        draftChanged()
        hasError = true
        message = "待处理记录不属于当前选定账户，未预检或写入。请切回对应账户并重新选择记录。"
    }
    private func isStale(_ error: any Error) -> Bool {
        (error as? LedgerStoreError) == .stalePlan || (error as? LedgerStoreError) == .invalidPlan
    }
}

public enum LedgerManualKind: String, CaseIterable, Sendable {
    case deposit, withdrawal, dividend, interest, fee, dividendWithholding, interestWithholding, otherTax
    case equityTrade, optionTrade, optionSettlement, split, returnOfCapital, cashInLieu, transferIn, transferOut, advanced
    public var title: String {
        switch self {
        case .deposit: "入金"
        case .withdrawal: "出金"
        case .dividend: "现金股息"
        case .interest: "利息"
        case .fee: "独立费用"
        case .dividendWithholding: "股息预扣税"
        case .interestWithholding: "利息预扣税"
        case .otherTax: "其他税费"
        case .equityTrade: "股票 / ETF 成交"
        case .optionTrade: "期权成交"
        case .optionSettlement: "到期 / 行权 / 指派"
        case .split: "拆股 / 并股"
        case .returnOfCapital: "资本返还 ROC"
        case .cashInLieu: "零股现金"
        case .transferIn: "转入证券"
        case .transferOut: "转出证券"
        case .advanced: "分拆 / 合并 / 合约调整高级输入"
        }
    }
}

/// A native form preserves explicit strings until validation. Missing fees, cost,
/// deliverable terms and lot choices are never converted to zero or guessed.
public struct LedgerManualDraft: Equatable, Sendable {
    public var id = UUID().uuidString
    public var kind: LedgerManualKind = .deposit
    public var timestamp = "", sequence = "", sourceSystem = "manual", externalID = "", evidence = "", notes = ""
    public var securityID = "", symbol = "", securityKind: LedgerSecurityKind = .stock
    public var quantity = "", unitPrice = "", fee = "", amount = "", openingLotID = ""
    public var side: LedgerSide = .buy
    public var effect: LedgerTradeEffect = .open
    public var positionSide: LedgerPositionSide = .long
    public var lots: [String: String] = [:]
    public var fractionQuantities: [String: String] = [:], fractionCash: [String: String] = [:]
    public var ratio = "", confirmedBy = "", corporateActionEventID = ""
    public var historicalCost = "", acquiredAt = "", eventMarketValue = "", reportedTaxBasis = ""
    public var rollGroupID = "", multiLegGroupID = ""
    public var strategyEnabled = false, strategyID = "", successDefinition = "", maximumAcquisitionPrice = ""
    public var purpose: LedgerStrategyPurpose = .premiumIncome
    public var unassignedCountsAsSuccess = false
    public var occSymbol = "", contractVersionID = "", effectiveFrom = "", effectiveTo = ""
    public var quoteMultiplier = "", exerciseConsideration = "", deliverableQuantity = "", deliverableCash = ""
    public var tradingEndsAt = "", exerciseDeadline = "", settlementAt = "", memoReference = ""
    public var exerciseStyle: LedgerExerciseStyle = .american
    public var settlementAction: LedgerSettlementAction = .expiration
    public var existingOption: LedgerOptionVersion?
    public var acquiredLotID = ""
    public var equityLots: [String: String] = [:]
    public var advancedPayload = ""
    public init() {}

    public func event(accountID: String) throws -> LedgerEvent {
        func decimal(_ text: String) throws -> Money { try Money(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        func date(_ text: String) throws -> Date { try LedgerCSV.timestamp(text) }
        func security() -> LedgerSecurity { .init(id: securityID, symbol: symbol, kind: securityKind) }
        func selections(_ values: [String:String]) throws -> [LedgerLotSelection] {
            try values.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map {
                .init(lotID: $0.key, quantity: try decimal($0.value))
            }
        }
        func strategy() throws -> LedgerStrategy? {
            guard strategyEnabled else { return nil }
            return .init(id: strategyID, purpose: purpose, successDefinition: successDefinition,
                maximumAcquisitionPrice: maximumAcquisitionPrice.isEmpty ? nil : try decimal(maximumAcquisitionPrice),
                unassignedCountsAsSuccess: unassignedCountsAsSuccess)
        }
        func option() throws -> LedgerOptionVersion {
            if let existingOption { return existingOption }
            return .init(occSymbol: occSymbol, versionID: contractVersionID,
                effectiveFrom: try date(effectiveFrom), effectiveTo: effectiveTo.isEmpty ? nil : try date(effectiveTo),
                quoteMultiplier: try decimal(quoteMultiplier), exerciseConsideration: try decimal(exerciseConsideration),
                deliverables: [.init(security: security(), quantity: try decimal(deliverableQuantity), basisWeight: try Money("1"))],
                deliverableCash: try decimal(deliverableCash), exerciseStyle: exerciseStyle,
                tradingEndsAt: try date(tradingEndsAt), exerciseDeadline: try date(exerciseDeadline),
                settlementAt: try date(settlementAt), memoReferences: [memoReference])
        }
        let payload: LedgerPayload
        switch kind {
        case .deposit, .withdrawal, .dividend, .interest, .fee, .dividendWithholding, .interestWithholding, .otherTax:
            guard let cashKind = LedgerCashKind(rawValue: kind.rawValue) else { throw LedgerError.invalidAmount }
            payload = .cash(.init(kind: cashKind, amount: try decimal(amount), securityID: securityID.isEmpty ? nil : securityID))
        case .equityTrade, .optionTrade:
            let instrument: LedgerInstrument = kind == .optionTrade ? .option(try option()) : .equity(security())
            payload = .trade(.init(instrument: instrument, side: side, effect: effect,
                quantity: try decimal(quantity), unitPrice: try decimal(unitPrice), fee: try decimal(fee),
                openingLotID: effect == .open ? openingLotID : nil, selections: try selections(lots), strategy: try strategy()))
        case .optionSettlement:
            let contract = try option()
            guard contract.deliverables.count == 1 else { throw LedgerError.invalidContract }
            let acquired = acquiredLotID.isEmpty ? [:] : [contract.deliverables[0].security.id: acquiredLotID]
            payload = .optionSettlement(.init(contract: contract, action: settlementAction, side: positionSide,
                quantity: try decimal(quantity), fee: try decimal(fee), optionSelections: try selections(lots),
                equitySelections: try selections(equityLots), acquiredLotIDs: acquired, evidence: evidence))
        case .split:
            let keys = Set(fractionQuantities.keys).union(fractionCash.keys)
            let fractions = try keys.sorted().filter {
                !(fractionQuantities[$0] ?? "").isEmpty || !(fractionCash[$0] ?? "").isEmpty
            }.map { key in
                LedgerSplitFraction(lotID: key, quantityDisposed: try decimal(fractionQuantities[key] ?? ""),
                                    cash: try decimal(fractionCash[key] ?? ""))
            }
            payload = .split(.init(securityID: securityID, ratio: try decimal(ratio), fractions: fractions,
                                   evidence: evidence, confirmedBy: confirmedBy))
        case .returnOfCapital:
            let allocations = try Dictionary(uniqueKeysWithValues: lots.filter { !$0.value.isEmpty }.map {
                ($0.key, try decimal($0.value))
            })
            payload = .returnOfCapital(.init(allocations: allocations, evidence: evidence, confirmedBy: confirmedBy))
        case .cashInLieu:
            payload = .cashInLieu(.init(selections: try selections(lots), cash: try decimal(amount), fee: try decimal(fee),
                corporateActionEventID: corporateActionEventID, evidence: evidence))
        case .transferIn:
            payload = .transferIn(.init(lotID: openingLotID, instrument: .equity(security()), side: positionSide,
                quantity: try decimal(quantity), historicalCost: try decimal(historicalCost), acquiredAt: try date(acquiredAt),
                eventMarketValue: try decimal(eventMarketValue),
                userReportedTaxBasis: reportedTaxBasis.isEmpty ? nil : try decimal(reportedTaxBasis),
                strategy: try strategy(), evidence: evidence))
        case .transferOut:
            payload = .transferOut(.init(instrument: .equity(security()), side: positionSide, quantity: try decimal(quantity),
                selections: try selections(lots), eventMarketValue: try decimal(eventMarketValue), evidence: evidence))
        case .advanced:
            guard advancedPayload.utf8.count <= LedgerCSV.maximumFieldBytes else { throw LedgerCSVError.budgetExceeded }
            payload = try JSONDecoder().decode(LedgerPayload.self, from: Data(advancedPayload.utf8))
        }
        let sequenceValue: Int?
        if sequence.isEmpty { sequenceValue = nil }
        else {
            guard let parsed = Int(sequence), parsed >= 0 else { throw LedgerError.ambiguousOrdering }
            sequenceValue = parsed
        }
        let event = LedgerEvent(id: id, accountID: accountID, effectiveAt: try date(timestamp),
            providerSequence: sequenceValue,
            source: .init(sourceSystem: sourceSystem, externalTransactionID: externalID, evidence: evidence),
            payload: payload, rollGroupID: rollGroupID.isEmpty ? nil : rollGroupID,
            multiLegGroupID: multiLegGroupID.isEmpty ? nil : multiLegGroupID, notes: notes)
        try event.validate()
        return event
    }
}
