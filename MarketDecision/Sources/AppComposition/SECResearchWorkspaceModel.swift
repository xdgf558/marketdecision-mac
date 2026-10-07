import Foundation
import Observation
import CoreDomain
import DataContracts
import FundamentalsEngine
import Persistence

public enum SECResearchConfigurationError: Error { case invalidContact, networkDisabled }

/// Contact identity belongs only to this explicit request. It is never part of the saved
/// document, source metadata, error message or diagnostic log.
public struct SECContactIdentity: Sendable {
    public let email: String
    public var userAgent: String { "MarketDecision/0.1 " + email }
    public init(email: String) throws {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 160,
              clean.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}\z"#,
                          options: .regularExpression) != nil,
              !clean.contains("..") else { throw SECResearchConfigurationError.invalidContact }
        self.email = clean
    }
}

public protocol SECResearchWorkspaceStorage: Sendable {
    func savedResearch() async throws -> [SECResearchSummary]
    func open(id: UUID) async throws -> SECResearchDocument
}
extension SECResearchStore: SECResearchWorkspaceStorage {}

public protocol SECFinancialReportWorkspaceStorage: Sendable {
    func prepareFinancialReport(parentID: UUID, executionDate: Date) async throws -> SECFinancialReportDraft
    func saveFinancialReport(_ document: SECFinancialReportDocument, expectedRevision: UUID) async throws
    func savedFinancialReports(parentID: UUID?) async throws -> [SECFinancialReportSummary]
    func openFinancialReport(id: UUID) async throws -> SECFinancialReportDocument
}
extension SECResearchStore: SECFinancialReportWorkspaceStorage {}

public protocol SECValuationWorkspaceStorage: Sendable {
    func valuationSourceDocument(parentReportID: UUID) async throws -> SECResearchDocument
    func prepareValuationSupplement(parentReportID: UUID, evidence: SECValuationInputEvidence,
        executionDate: Date) async throws -> SECValuationSupplementDraft
    func saveValuationSupplement(_ document: SECValuationSupplementDocument, expectedRevision: UUID) async throws
    func savedValuationSupplements(parentReportID: UUID?) async throws -> [SECValuationSupplementSummary]
    func openValuationSupplement(id: UUID) async throws -> SECValuationSupplementDocument
}
extension SECResearchStore: SECValuationWorkspaceStorage {}

public enum SECFinancialReportDisplayState: Sendable, Equatable {
    case notVerified, generated, matched, mismatched, failed
}

/// Native form values retain explicit source excerpts. No share count, class universe or
/// split basis is inferred from ticker metadata or a weighted-average EPS denominator.
public struct SECValuationShareClassDraft: Sendable, Identifiable {
    public var id = UUID()
    public var classID = "", symbol = "", countExcerpt = "", countContextExcerpt = "", identityExcerpt = ""
    public init() {}
}
public struct SECValuationShareEvidenceDraft: Sendable {
    public var sourceReference = "", coverDate = "", accessionNumber = ""
    public var completenessExcerpt = "", rationale = ""
    public var classes: [SECValuationShareClassDraft] = [.init()]
    public init() {}
}
public struct SECValuationSplitEvidenceDraft: Sendable {
    public var sourceReference = "", excerpt = "", basisDate = "", rationale = ""
    public init() {}
}

public typealias SECResearchImport = @Sendable (String, SECContactIdentity,
    @escaping @Sendable (SECResearchProgress) async -> Void) async throws -> SECResearchDocument

/// A page owns its task, progress and replay status. Opening a page only reads the isolated
/// local store. Neither startup, selection nor replay constructs a network session.
@MainActor @Observable public final class SECResearchWorkspaceModel {
    public private(set) var ticker = "MSFT"
    public let networkAvailable: Bool
    public private(set) var document: SECResearchDocument?
    public private(set) var saved: [SECResearchSummary] = []
    public private(set) var progress: SECResearchProgress?
    public private(set) var isBusy = false
    public private(set) var message: String?
    public private(set) var listError: String?
    public private(set) var hasError = false
    public private(set) var recomputationState: OfflineIssuerRecomputationState = .notVerified
    public var canDisplayValues: Bool { document != nil && recomputationState == .matched }
    public private(set) var financialReport: SECFinancialReportDocument?
    public private(set) var savedFinancialReports: [SECFinancialReportSummary] = []
    public private(set) var financialReportState: SECFinancialReportDisplayState = .notVerified
    public private(set) var financialReportIsSaved = false
    public private(set) var financialMessage: String?
    public private(set) var financialListError: String?
    public private(set) var financialHasError = false
    public var canGenerateFinancialReport: Bool { !isBusy && document != nil && financialStorage != nil }
    public var canSaveFinancialReport: Bool {
        !isBusy && financialReport != nil && financialDraftRevision != nil && !financialReportIsSaved
            && canDisplayFinancialReport
    }
    public var canDisplayFinancialReport: Bool {
        financialReport != nil && (financialReportState == .generated || financialReportState == .matched)
    }
    public private(set) var valuationSupplement: SECValuationSupplementDocument?
    public private(set) var savedValuationSupplements: [SECValuationSupplementSummary] = []
    public private(set) var valuationState: SECFinancialReportDisplayState = .notVerified
    public private(set) var valuationIsSaved = false
    public private(set) var valuationMessage: String?
    public private(set) var valuationListError: String?
    public private(set) var valuationHasError = false
    public private(set) var valuationSourceDocument: SECResearchDocument?
    public var canGenerateValuationSupplement: Bool {
        !isBusy && financialReport != nil && financialReportIsSaved && valuationStorage != nil
    }
    public var canSaveValuationSupplement: Bool {
        !isBusy && valuationSupplement != nil && valuationDraftRevision != nil && !valuationIsSaved
            && canDisplayValuationSupplement
    }
    public var canDisplayValuationSupplement: Bool {
        valuationSupplement != nil && (valuationState == .generated || valuationState == .matched)
    }
    private let storage: any SECResearchWorkspaceStorage
    private let financialStorage: (any SECFinancialReportWorkspaceStorage)?
    private let valuationStorage: (any SECValuationWorkspaceStorage)?
    private let valuationReplay: @Sendable (SECValuationSupplementDocument) async throws -> Bool
    private var valuationDraftRevision: UUID?
    private let importer: SECResearchImport
    private let replay: @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult
    private let financialReplay: @Sendable (SECFinancialReportDocument) async throws -> Bool
    private let now: @Sendable () -> Date
    private var financialDraftRevision: UUID?
    private var cancelFinancialWork: (@Sendable () -> Void)?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    public init(storage: any SECResearchWorkspaceStorage, networkAvailable: Bool,
                importer: @escaping SECResearchImport,
                replay: @escaping @Sendable (SECResearchDocument) async throws -> FinancialNormalizationResult = {
                    try $0.recompute()
                },
                financialStorage: (any SECFinancialReportWorkspaceStorage)? = nil,
                valuationStorage: (any SECValuationWorkspaceStorage)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                valuationReplay: @escaping @Sendable (SECValuationSupplementDocument) async throws -> Bool = { document in
                    let replay = try await document.valuation.recompute()
                    return try document.valuation.cachedReportMatches(replay)
                },
                financialReplay: @escaping @Sendable (SECFinancialReportDocument) async throws -> Bool = { document in
                    let result = try await document.financials.recompute()
                    return try document.financials.cachedReportsMatch(result)
                }) {
        self.storage = storage; self.networkAvailable = networkAvailable
        self.importer = importer; self.replay = replay
        self.financialStorage = financialStorage; self.now = now; self.financialReplay = financialReplay
        self.valuationStorage = valuationStorage; self.valuationReplay = valuationReplay
    }

    public func chooseTicker(_ value: String) {
        guard !isBusy else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker != value else { return }
        generation = UUID(); ticker = value; clearDocument(); message = nil; hasError = false
    }

    public func load() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        async let research: Void = reloadList(token)
        async let reports: Void = reloadFinancialList(token)
        async let supplements: Void = reloadValuationList(token)
        _ = await (research, reports, supplements)
    }

    /// Called only by the explicit import action. A busy page does not start a second task.
    @discardableResult public func startImport(email: String) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let contact: SECContactIdentity
        do {
            guard networkAvailable else { throw SECResearchConfigurationError.networkDisabled }
            contact = try SECContactIdentity(email: email)
            try EquityRecord.validateSymbol(ticker)
        } catch {
            clearDocument(); hasError = true
            message = networkAvailable ? "请输入有效的股票代码和 SEC 联系邮箱。" : "本构建的 SEC 导入服务不可用，仍可打开本地已保存研究。"
            return nil
        }
        let token = begin(clear: true), symbol = ticker
        task = Task { [weak self, importer] in
            do {
                let result = try await importer(symbol, contact) { [weak self] value in
                    await self?.receive(value, token: token)
                }
                guard let self, self.generation == token else { return }
                try Task.checkCancellation()
                try result.validate()
                guard result.ticker == symbol else { throw ContractError.mismatchedSource }
                self.document = result; self.ticker = result.ticker
                self.message = "导入研究已保存；请显式重算核对后查看标准化数值。缺项与访问范围保留。"
                await self.reloadList(token, committed: true)
                self.finish(token)
            } catch {
                guard let self, self.generation == token else { return }
                self.hasError = !Task.isCancelled
                self.message = Task.isCancelled ? "导入已取消；已接收的源页可能保留，取消不撤销已完成的保存。"
                    : Self.failureMessage(error)
                self.finish(token)
            }
        }
        return task
    }

    public func open(_ id: UUID) async {
        guard !isBusy else { return }
        let token = begin(clear: true)
        defer { finish(token) }
        do {
            let result = try await storage.open(id: id)
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            document = result; ticker = result.ticker
            message = "已打开冻结研究；数值缓存仍待显式重算核对。"
        } catch {
            guard generation == token else { return }
            hasError = true; message = "研究未能打开或未通过完整性检查；未显示旧结果。"
        }
    }

    public func recompute() async {
        guard !isBusy, let document else { return }
        let token = begin(clear: false)
        recomputationState = .notVerified
        defer { finish(token) }
        do {
            let result = try await replay(document)
            guard generation == token else { return }
            try Task.checkCancellation()
            if result == document.normalization {
                recomputationState = .matched; message = "冻结输入重算一致；不授予历史时点或投资分析资格。"
            } else {
                recomputationState = .mismatched; hasError = true
                message = "重算与缓存不一致，数值已隐藏；原记录未修改。"
            }
        } catch {
            guard generation == token else { return }
            recomputationState = .failed; hasError = true
            message = "重算未完成，数值保持隐藏；原记录未修改。"
        }
    }

    /// Preparation captures the original store revision before report generation. Save
    /// uses that exact draft baseline, including after a recoverable storage failure.
    public func generateFinancialReport() async {
        guard canGenerateFinancialReport, let document, let financialStorage else { return }
        let token = beginFinancial(clearReport: true)
        defer { finish(token) }
        do {
            let executionDate = now()
            let draft = try await financialOperation {
                try await financialStorage.prepareFinancialReport(parentID: document.id, executionDate: executionDate)
            }
            guard generation == token else { return }
            try Task.checkCancellation(); try draft.document.validate()
            guard draft.document.parentDocumentID == document.id, draft.document.ticker == document.ticker,
                  draft.document.cutoff == document.cutoff else { throw ContractError.mismatchedSource }
            financialReport = draft.document; financialDraftRevision = draft.expectedRevision
            financialReportState = .generated
            financialMessage = "已从选定冻结研究生成财务报告；尚未保存。期间及分类缺项保持明确。"
        } catch {
            guard generation == token else { return }
            financialHasError = true; financialMessage = Self.financialFailureMessage(error)
        }
    }

    public func saveFinancialReport() async {
        guard canSaveFinancialReport, let financialReport, let financialDraftRevision, let financialStorage else { return }
        let token = beginFinancial()
        defer { finish(token) }
        do {
            try Task.checkCancellation()
            try await financialOperation {
                try await financialStorage.saveFinancialReport(financialReport, expectedRevision: financialDraftRevision)
            }
        } catch {
            guard generation == token else { return }
            financialHasError = true
            if error as? SnapshotError == .stalePlan {
                self.financialDraftRevision = nil
                financialMessage = "研究库已变化，报告未保存。请重新打开源研究并生成；不会自动改用新的保存基线。"
            } else {
                financialMessage = "报告保存未完成；草稿保留，可重试。原有研究和报告未被覆盖。"
            }
            return
        }
        guard generation == token else { return }
        financialReportIsSaved = true; self.financialDraftRevision = nil
        financialMessage = "财务报告已保存，绑定原冻结研究；重开后仍需显式重算核对。"
        await reloadFinancialList(token, committed: true)
    }

    public func openFinancialReport(_ id: UUID) async {
        guard !isBusy, let financialStorage else { return }
        let token = beginFinancial(clearReport: true)
        defer { finish(token) }
        do {
            let result = try await financialOperation { try await financialStorage.openFinancialReport(id: id) }
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            if document?.id != result.parentDocumentID {
                document = nil; recomputationState = .notVerified
            }
            financialReport = result; financialReportIsSaved = true; ticker = result.ticker
            financialMessage = "已打开保存的财务报告；缓存数值在显式重算核对前保持隐藏。"
        } catch {
            guard generation == token else { return }
            financialHasError = true
            financialMessage = "财务报告或绑定源研究未通过检查；未显示旧报告，源研究列表仍可使用。"
        }
    }

    public func recomputeFinancialReport() async {
        guard !isBusy, let financialReport else { return }
        let token = beginFinancial()
        financialReportState = .notVerified
        defer { finish(token) }
        do {
            let replay = financialReplay
            let matches = try await financialOperation { try await replay(financialReport) }
            guard generation == token else { return }
            try Task.checkCancellation()
            financialReportState = matches ? .matched : .mismatched
            financialHasError = !matches
            financialMessage = matches ? "三个财务模型的冻结输入重算一致；不授予估值、评分或历史 PIT 资格。"
                : "重算与报告缓存不一致，数值保持隐藏；原保存内容未修改。"
        } catch {
            guard generation == token else { return }
            financialReportState = .failed; financialHasError = true
            financialMessage = "财务报告重算未完成，数值保持隐藏；原保存内容未修改。"
        }
    }

    public func loadFinancialReports() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        await reloadFinancialList(token)
    }

    /// Source selection is explicit and bound to the selected saved financial report.
    /// Opening source evidence neither verifies cached numbers nor starts a request.
    public func loadValuationSources() async {
        guard canGenerateValuationSupplement, let report = financialReport, let valuationStorage else { return }
        let token = beginValuation()
        valuationSourceDocument = nil
        defer { finish(token) }
        do {
            let source = try await financialOperation {
                try await valuationStorage.valuationSourceDocument(parentReportID: report.id)
            }
            guard generation == token else { return }
            try Task.checkCancellation(); try source.validate()
            guard source.id == report.parentDocumentID, source.ticker == report.ticker,
                  source.cutoff == report.cutoff else { throw ContractError.mismatchedSource }
            valuationSourceDocument = source
            valuationMessage = "已载入报告绑定的原始来源。仅按可核对原文补充证据；缺项可以保留。"
        } catch {
            guard generation == token else { return }
            valuationHasError = true
            valuationMessage = "绑定来源未能通过检查；证据输入保持关闭，已有报告未修改。"
        }
    }

    /// The citation is found as one exact UTF-8 byte range in the selected retained source.
    /// An ambiguous phrase must be made more specific rather than choosing an arbitrary match.
    public func generateValuationSupplement(applicability: SECIndustryApplicability,
        sourceReference: String, excerpt: String, rationale: String,
        shareEvidence: SECValuationShareEvidenceDraft? = nil,
        splitEvidence: SECValuationSplitEvidenceDraft? = nil,
        capturedPrices: [SECValuationPriceEvidence] = []) async {
        guard canGenerateValuationSupplement, let parent = financialReport else { return }
        do {
            let reviewedAt = now()
            func anchor(reference: String, text: String, context: String? = nil) throws -> SECValuationSourceAnchor {
                guard let sourceDocument = valuationSourceDocument, sourceDocument.id == parent.parentDocumentID,
                      let source = sourceDocument.sources.first(where: { $0.reference == reference })
                else { throw ContractError.mismatchedSource }
                func uniqueRange(_ bytes: Data, in source: Data) throws -> Range<Int> {
                    guard !bytes.isEmpty, let range = source.range(of: bytes),
                          source.range(of: bytes, in: (range.lowerBound + 1)..<source.endIndex) == nil
                    else { throw ContractError.mismatchedSource }
                    return range
                }
                let bytes = Data(text.utf8), offset: Int
                if let context, !context.isEmpty {
                    let contextBytes = Data(context.utf8)
                    let outer = try uniqueRange(contextBytes, in: source.bytes)
                    let inner = try uniqueRange(bytes, in: contextBytes)
                    offset = outer.lowerBound + inner.lowerBound
                } else { offset = try uniqueRange(bytes, in: source.bytes).lowerBound }
                return try SECValuationSourceAnchor(sourceReference: source.reference,
                    sourceHash: source.contentHash, byteOffset: offset, excerpt: bytes)
            }
            let industry: SECIndustryReview? = applicability == .unknown ? nil : try .init(
                applicability: applicability, reviewedAt: reviewedAt,
                rationale: rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                anchors: [anchor(reference: sourceReference, text: excerpt)])
            let shares: SECShareClassReview?
            if let form = shareEvidence {
                let classes = try form.classes.map { item in
                    let identity = try anchor(reference: form.sourceReference, text: item.identityExcerpt)
                    let context = item.countContextExcerpt.isEmpty ? nil : try anchor(reference: form.sourceReference, text: item.countContextExcerpt)
                    return try SECReviewedShareClass(classID: item.classID.trimmingCharacters(in: .whitespacesAndNewlines),
                        symbol: item.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                        outstandingShares: Money(item.countExcerpt),
                        countAnchor: anchor(reference: form.sourceReference, text: item.countExcerpt, context: item.countContextExcerpt),
                        identityAnchors: [identity] + (context.map { [$0] } ?? []))
                }
                shares = try .init(cik: parent.financials.evidence.cik,
                    coverDate: MarketDate(iso8601: form.coverDate), accessionNumber: form.accessionNumber,
                    classes: classes, completenessAnchors: [anchor(reference: form.sourceReference, text: form.completenessExcerpt)],
                    reviewedAt: reviewedAt, rationale: form.rationale)
            } else { shares = nil }
            let split: SECSplitBasisReview?
            if let form = splitEvidence {
                guard let shares, let start = parent.financials.evidence.quarters.first?.start else {
                    throw SECValuationError.invalidEvidence
                }
                let facts = parent.financials.inputSnapshot.financials.input.normalization.values
                let ids = Set(facts.filter { $0.unit == "USD/shares" || $0.unit == "shares" }.flatMap(\.sourceFactIDs)).sorted()
                split = try .init(classIDs: shares.classes.map(\.classID), windowStart: start,
                    basisDate: MarketDate(iso8601: form.basisDate), coveredFactIDs: ids,
                    anchors: [anchor(reference: form.sourceReference, text: form.excerpt)],
                    reviewedAt: reviewedAt, rationale: form.rationale)
            } else { split = nil }
            guard capturedPrices.allSatisfy({ $0.record.symbol == parent.ticker }) else {
                throw SECValuationError.invalidEvidence
            }
            await generateValuationSupplement(evidence: .init(industryReview: industry, shareClasses: shares,
                splitBasis: split, prices: capturedPrices))
        } catch {
            valuationHasError = true
            valuationMessage = "证据未提交。请核对日期、申报、完整股类与判断理由；每段引文须在选定来源唯一出现，股数须引用原文未缩放的完整整数。"
        }
    }

    public func generateValuationSupplement(evidence: SECValuationInputEvidence) async {
        guard canGenerateValuationSupplement, let parent = financialReport, let valuationStorage else { return }
        let token = beginValuation(clearReport: true)
        defer { finish(token) }
        do {
            let executionDate = now()
            let draft = try await financialOperation {
                try await valuationStorage.prepareValuationSupplement(parentReportID: parent.id,
                    evidence: evidence, executionDate: executionDate)
            }
            guard generation == token else { return }
            try Task.checkCancellation(); try draft.document.validate()
            try draft.document.valuation.validateAccounting(parent.financials)
            guard draft.document.parentFinancialReportID == parent.id,
                  draft.document.parentResearchID == parent.parentDocumentID,
                  draft.document.parentResearchHash == parent.parentDocumentHash,
                  draft.document.ticker == parent.ticker, draft.document.cutoff == parent.cutoff
            else { throw ContractError.mismatchedSource }
            valuationSupplement = draft.document; valuationDraftRevision = draft.expectedRevision
            valuationState = .generated
            valuationMessage = "已从保存的财务报告及补充证据生成研究结果；尚未保存。未满足资格的估值与总分保持缺项。"
        } catch {
            guard generation == token else { return }
            valuationHasError = true
            valuationMessage = "补充报告未能生成。请核对证据、原报告和来源绑定；不会猜测缺失输入或请求行情。"
        }
    }

    public func saveValuationSupplement() async {
        guard canSaveValuationSupplement, let valuationSupplement, let valuationDraftRevision, let valuationStorage else { return }
        let token = beginValuation()
        defer { finish(token) }
        do {
            try Task.checkCancellation()
            try await financialOperation {
                try await valuationStorage.saveValuationSupplement(valuationSupplement, expectedRevision: valuationDraftRevision)
            }
        } catch {
            guard generation == token else { return }
            valuationHasError = true
            if error as? SnapshotError == .stalePlan {
                self.valuationDraftRevision = nil
                valuationMessage = "研究库已变化，补充报告未保存。请重新生成；不会替换原保存基线。"
            } else {
                valuationMessage = "补充报告保存未完成；草稿和原基线保留，可重试。"
            }
            return
        }
        guard generation == token else { return }
        valuationIsSaved = true; self.valuationDraftRevision = nil
        valuationMessage = "补充报告已保存，绑定原财务报告及 SEC 研究；重开后仍需显式重算核对。"
        await reloadValuationList(token, committed: true)
    }

    public func openValuationSupplement(_ id: UUID) async {
        guard !isBusy, let valuationStorage else { return }
        let token = beginValuation(clearReport: true)
        valuationSourceDocument = nil
        defer { finish(token) }
        do {
            let result = try await financialOperation { try await valuationStorage.openValuationSupplement(id: id) }
            guard generation == token else { return }
            try Task.checkCancellation(); try result.validate()
            guard result.id == id else { throw ContractError.mismatchedSource }
            if financialReport?.id != result.parentFinancialReportID { clearFinancialReport() }
            if document?.id != result.parentResearchID { document = nil; recomputationState = .notVerified }
            valuationSupplement = result; valuationIsSaved = true; ticker = result.ticker
            valuationMessage = "已打开补充报告；缓存结果在本次显式重算核对前保持隐藏。"
        } catch {
            guard generation == token else { return }
            valuationHasError = true
            valuationMessage = "补充报告或绑定原件未通过检查；未显示旧结果，其他研究列表仍可使用。"
        }
    }

    public func recomputeValuationSupplement() async {
        guard !isBusy, let valuationSupplement else { return }
        let token = beginValuation()
        valuationState = .notVerified
        defer { finish(token) }
        do {
            let replay = valuationReplay
            let matches = try await financialOperation { try await replay(valuationSupplement) }
            guard generation == token else { return }
            try Task.checkCancellation()
            valuationState = matches ? .matched : .mismatched
            valuationHasError = !matches
            valuationMessage = matches ? "冻结证据重算一致；研究用途及资格缺口保留，不授予行情、历史 PIT 或交易资格。"
                : "重算与补充报告缓存不一致，结果保持隐藏；原保存内容未修改。"
        } catch {
            guard generation == token else { return }
            valuationState = .failed; valuationHasError = true
            valuationMessage = "补充报告重算未完成，结果保持隐藏；原保存内容未修改。"
        }
    }

    public func loadValuationSupplements() async {
        guard !isBusy else { return }
        let token = begin(clear: false)
        defer { finish(token) }
        await reloadValuationList(token)
    }

    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        cancelFinancialWork?(); cancelFinancialWork = nil; isBusy = false; progress = nil
        clearDocument(); hasError = false
        message = "操作已取消；已接收的源页或已提交的研究可能保留，可重新载入列表检查。"
    }
    public func disappear() {
        cancel(); message = nil; saved = []; listError = nil
        savedFinancialReports = []; financialListError = nil
        savedValuationSupplements = []; valuationListError = nil
    }
    private func receive(_ value: SECResearchProgress, token: UUID) {
        guard generation == token else { return }; progress = value
    }
    private func begin(clear: Bool) -> UUID {
        generation = UUID(); isBusy = true; progress = nil; message = nil; hasError = false
        if clear { clearDocument() }
        return generation
    }
    private func beginFinancial(clearReport: Bool = false) -> UUID {
        let token = begin(clear: false)
        if clearReport { clearFinancialReport() }
        financialMessage = nil; financialHasError = false
        return token
    }
    private func beginValuation(clearReport: Bool = false) -> UUID {
        let token = begin(clear: false)
        if clearReport { clearValuationSupplement() }
        valuationMessage = nil; valuationHasError = false
        return token
    }
    private func clearValuationSupplement() {
        valuationSupplement = nil; valuationDraftRevision = nil; valuationIsSaved = false
        valuationState = .notVerified; valuationMessage = nil; valuationHasError = false
    }
    private func clearDocument() {
        document = nil; recomputationState = .notVerified; clearFinancialReport()
    }
    private func clearFinancialReport() {
        clearValuationSupplement(); valuationSourceDocument = nil
        financialReport = nil; financialDraftRevision = nil; financialReportIsSaved = false
        financialReportState = .notVerified; financialMessage = nil; financialHasError = false
    }
    private func finish(_ token: UUID) {
        if generation == token { isBusy = false; task = nil; cancelFinancialWork = nil }
    }
    private func financialOperation<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let pending = Task { try await operation() }
        cancelFinancialWork = { pending.cancel() }
        return try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: { pending.cancel() }
    }
    private func reloadList(_ token: UUID, committed: Bool = false) async {
        do {
            let rows = try await storage.savedResearch()
            guard generation == token else { return }
            try Task.checkCancellation(); saved = rows; listError = nil
        } catch {
            guard generation == token else { return }
            saved = []; listError = "保存列表无法读取，请重新载入。"
            if committed { message = "研究已保存，但列表刷新失败；请重新载入，避免重复导入。" }
        }
    }
    private func reloadFinancialList(_ token: UUID, committed: Bool = false) async {
        guard let financialStorage else { return }
        do {
            let rows = try await financialStorage.savedFinancialReports(parentID: nil)
            guard generation == token else { return }
            try Task.checkCancellation(); savedFinancialReports = rows; financialListError = nil
        } catch {
            guard generation == token else { return }
            savedFinancialReports = []; financialListError = "财务报告列表无法读取，请单独重新载入。源研究列表仍可使用。"
            if committed { financialMessage = "财务报告已保存，但报告列表刷新失败；请重新载入，避免重复保存。" }
        }
    }
    private func reloadValuationList(_ token: UUID, committed: Bool = false) async {
        guard let valuationStorage else { return }
        do {
            let rows = try await valuationStorage.savedValuationSupplements(parentReportID: nil)
            guard generation == token else { return }
            try Task.checkCancellation(); savedValuationSupplements = rows; valuationListError = nil
        } catch {
            guard generation == token else { return }
            savedValuationSupplements = []; valuationListError = "补充报告列表无法读取，可单独重试；源研究及财务报告列表仍可使用。"
            if committed { valuationMessage = "补充报告已保存，但列表刷新失败；请重新载入，避免重复保存。" }
        }
    }
    private static func financialFailureMessage(_ error: any Error) -> String {
        switch error {
        case SECFinancialError.insufficientPeriods: "冻结研究缺少足够的连续季度证据，暂不能生成财务报告；不会推测财年或补齐期间。"
        case SECFinancialError.ambiguousPeriods: "冻结研究的财务期间证据有歧义，暂不能生成财务报告；请先核查来源。"
        case SnapshotError.stalePlan: "生成期间研究库已变化，请重新打开源研究后再生成。"
        default: "财务报告未能生成；请检查冻结研究及期间证据。已有研究未修改，也未发起网络请求。"
        }
    }
    private static func failureMessage(_ error: any Error) -> String {
        // Only closed typed categories; never render provider descriptions, request headers or URLs.
        switch error {
        case SECResearchError.importInProgress: "另一个窗口正在导入 SEC 财报；请等待导入完成或取消结束后重试。已保存列表仍可查看。"
        case ProviderFailure.rateLimited: "SEC 暂时限流，导入未完成；请稍后手动重试，已接收的源页可能保留。"
        case ProviderFailure.symbolUnavailable: "未找到所选代码或申报文件；导入未完成。"
        default: "导入未完成；请检查访问配置或稍后重试。已接收的源页可能保留，不代表整次导入成功。"
        }
    }
}
