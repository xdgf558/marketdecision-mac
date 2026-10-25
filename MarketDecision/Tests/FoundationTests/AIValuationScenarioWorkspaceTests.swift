import Foundation
import Testing
import AIInsights
import SecuritySupport
import CoreDomain
@testable import AppComposition

private actor ScenarioWorkspaceProbe {
    var keys = 0
    var sends = 0
    func key() { keys += 1 }
    func send() { sends += 1 }
}
private actor ScenarioWorkspaceCredentials: CredentialStorage {
    func contains(reference: String) -> Bool { true }
    func save(_ secret: Data, reference: String) {}
    func delete(reference: String) {}
}
private actor ScenarioWorkspaceGate {
    var arrived = false
    var released = false
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var releases: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrived = true
        let pending = arrivals; arrivals.removeAll()
        pending.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        released = true
        let pending = releases; releases.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func scenarioWorkspaceInput(revenue: String = "1000") -> AIInsightInput {
    let source = "local.userReference"
    let metrics: [AIInsightMetric] = [
        .init(id: "base.revenue", label: "TTM 收入", value: revenue, unit: "USD", unavailable: nil, sourceIDs: ["local.base"]),
        .init(id: "reference.price", label: "手工参考价", value: "20", unit: "USD/share", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.shares", label: "已确认股数", value: "100", unit: "shares", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.marketCap", label: "参考市值", value: "2000", unit: "USD", unavailable: nil, sourceIDs: [source]),
        .init(id: "reference.pe", label: "市盈率", value: nil, unit: "multiple", unavailable: "missingInput", sourceIDs: [source]),
        .init(id: "reference.ps", label: "市销率", value: nil, unit: "multiple", unavailable: "missingInput", sourceIDs: [source]),
        .init(id: "reference.pfcf", label: "市现率", value: nil, unit: "multiple", unavailable: "missingInput", sourceIDs: [source])
    ]
    return AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
        cutoff: "2026-10-24T00:00:00Z", metrics: metrics,
        sources: [.init(id: "local.base", label: "合成财报"), .init(id: source, label: "用户确认的合成参考")],
        referenceValuation: .init(referenceAt: "2026-10-25T00:00:00Z", sharesAsOf: "2026-09-30"))
}

private func scenarioWorkspaceResponse(_ request: AIInsightRequest) throws -> AIInsightResult {
    let claim: [String: Any] = ["text": "这是主观合成情景假设，不代表已验证合理倍数。", "evidenceIDs": ["base.revenue", "reference.shares"]]
    let proposal: [String: Any] = ["method": AIPriceSalesScenarioProposal.currentMethod,
        "conservative": ["multiple": "1", "rationale": claim],
        "base": ["multiple": "2", "rationale": claim],
        "optimistic": ["multiple": "3", "rationale": claim]]
    let analysis: [String: Any] = ["summary": claim, "strengths": [], "risks": [], "questions": [],
        "limitations": [claim], "valuation": ["scope": "referenceMultiples", "interpretation": claim,
            "limitations": [claim], "scenarioProposal": proposal]]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: analysis), as: UTF8.self)
    return try request.parseResponse(JSONSerialization.data(withJSONObject: [
        "object": "response", "status": "completed", "model": request.model,
        "output": [["type": "message", "role": "assistant", "status": "completed",
                    "content": [["type": "output_text", "text": text, "annotations": []]]]]]))
}

@Suite("Explicit local AI scenario confirmation") @MainActor
struct AIValuationScenarioWorkspaceTests {
    private func workspace(_ probe: ScenarioWorkspaceProbe,
        respond: @escaping @Sendable (AIInsightRequest) async throws -> AIInsightResult = scenarioWorkspaceResponse
    ) -> AIInsightWorkspaceModel {
        AIInsightWorkspaceModel(credentials: CredentialSettingsModel(store: ScenarioWorkspaceCredentials()),
            networkAvailable: true, readKey: { await probe.key(); return Data("SYNTHETIC-KEY".utf8) },
            factory: {
                AIInsightSession(send: { request, _ in
                    await probe.send(); return try await respond(request)
                }, close: {})
            })
    }
    private func start(_ model: AIInsightWorkspaceModel, id: UUID,
                       input: AIInsightInput = scenarioWorkspaceInput()) throws -> Task<Void, Never> {
        try #require(model.start(reportID: id, model: AIInsightRequest.defaultModel) { input })
    }

    @Test func explicitConfirmationAloneCreatesPricesWithoutAnotherRequest() async throws {
        let probe = ScenarioWorkspaceProbe(), model = workspace(probe), id = UUID(), revision = UUID()
        model.select(reportID: id, revision: revision)
        #expect(model.valuationProposalID == nil && model.valuationScenarioCalculation == nil)
        await (try start(model, id: id)).value
        let ticket = try #require(model.valuationProposalID)
        #expect(model.valuationScenarioCalculation == nil)
        #expect(!model.confirmValuationScenarios(proposalID: UUID(), reportID: id, reportRevision: revision))
        #expect(!model.confirmValuationScenarios(proposalID: ticket, reportID: UUID(), reportRevision: revision))
        #expect(!model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: UUID()))
        #expect(model.valuationScenarioCalculation == nil)
        #expect(model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: revision))
        let prices = try #require(model.valuationScenarioCalculation)
        #expect(prices.rows.map { $0.price.decimalString } == ["10", "20", "30"])
        #expect(!model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: revision))
        #expect(model.valuationScenarioCalculation == prices)
        #expect(await probe.sends == 1)
        #expect(await probe.keys == 1)
    }

    @Test func referenceReportCredentialAndPageChangesRevokeConfirmedPrices() async throws {
        for action in ["reference", "revision", "report", "credentials", "cancel", "disappear"] {
            let probe = ScenarioWorkspaceProbe(), model = workspace(probe), id = UUID(), revision = UUID()
            model.select(reportID: id, revision: revision)
            await (try start(model, id: id)).value
            let ticket = try #require(model.valuationProposalID)
            #expect(model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: revision))
            switch action {
            case "reference":
                let now = try #require(ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z"))
                var draft = AIValuationReferenceDraft(now: now)
                draft.price = "21"; draft.shares = "100"; draft.sharesAsOf = "2026-09-30"
                draft.confirmedSingleClassSameBasis = true; draft.maySendReferenceData = true
                #expect(model.updateValuationReference(try draft.validated(now: now), reportID: id, reportRevision: revision))
            case "revision": model.select(reportID: id, revision: UUID())
            case "report": model.select(reportID: UUID(), revision: UUID())
            case "credentials": model.credentialsChanged()
            case "cancel": model.cancel()
            default: model.disappear()
            }
            #expect(model.valuationScenarioCalculation == nil && model.valuationProposalID == nil)
            #expect(!model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: revision))
            #expect(await probe.sends == 1)
            #expect(await probe.keys == 1)
        }
    }

    @Test func identicalReanalysisRequiresANewConfirmationAndRejectsOldTicket() async throws {
        let probe = ScenarioWorkspaceProbe(), model = workspace(probe), id = UUID(), revision = UUID()
        model.select(reportID: id, revision: revision)
        await (try start(model, id: id)).value
        let old = try #require(model.valuationProposalID)
        #expect(model.confirmValuationScenarios(proposalID: old, reportID: id, reportRevision: revision))
        let second = try start(model, id: id)
        #expect(model.valuationProposalID == nil && model.valuationScenarioCalculation == nil)
        #expect(!model.confirmValuationScenarios(proposalID: old, reportID: id, reportRevision: revision))
        await second.value
        let fresh = try #require(model.valuationProposalID)
        #expect(fresh != old && model.valuationScenarioCalculation == nil)
        #expect(!model.confirmValuationScenarios(proposalID: old, reportID: id, reportRevision: revision))
        #expect(model.confirmValuationScenarios(proposalID: fresh, reportID: id, reportRevision: revision))
        let current = model.valuationScenarioCalculation
        #expect(!model.confirmValuationScenarios(proposalID: old, reportID: id, reportRevision: revision))
        #expect(model.valuationScenarioCalculation == current)
        #expect(await probe.sends == 2)
    }

    @Test func cancelledOrSwitchedLateResponseCannotPublishApprovalOrPrices() async throws {
        for switchReport in [false, true] {
            let probe = ScenarioWorkspaceProbe(), gate = ScenarioWorkspaceGate(), id = UUID(), revision = UUID()
            let model = workspace(probe, respond: { request in
                await gate.hold(); return try scenarioWorkspaceResponse(request)
            })
            model.select(reportID: id, revision: revision)
            let task = try start(model, id: id)
            await gate.waitForArrival()
            if switchReport { model.select(reportID: UUID(), revision: UUID()) } else { model.cancel() }
            await gate.release(); await task.value
            #expect(model.result == nil && model.valuationProposalID == nil && model.valuationScenarioCalculation == nil)
            #expect(!model.isBusy)
            #expect(await probe.sends == 1)
        }
    }

    @Test func invalidProposalFromSessionCannotBypassFinalPublicationCheck() async throws {
        let probe = ScenarioWorkspaceProbe(), id = UUID()
        let model = workspace(probe, respond: { request in
            let valid = try scenarioWorkspaceResponse(request)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
            var analysis = try #require(object["analysis"] as? [String: Any])
            var valuation = try #require(analysis["valuation"] as? [String: Any])
            var proposal = try #require(valuation["scenarioProposal"] as? [String: Any])
            var base = try #require(proposal["base"] as? [String: Any])
            base["multiple"] = "1"; proposal["base"] = base
            valuation["scenarioProposal"] = proposal; analysis["valuation"] = valuation; object["analysis"] = analysis
            return try JSONDecoder().decode(AIInsightResult.self, from: JSONSerialization.data(withJSONObject: object))
        })
        model.select(reportID: id, revision: UUID())
        await (try start(model, id: id)).value
        #expect(model.hasError && model.result == nil)
        #expect(model.valuationProposalID == nil && model.valuationScenarioCalculation == nil)
        #expect(await probe.sends == 1)
    }

    @Test func unrepresentablePriceNeverBecomesZeroAndDoesNotResend() async throws {
        let probe = ScenarioWorkspaceProbe(), model = workspace(probe), id = UUID(), revision = UUID()
        model.select(reportID: id, revision: revision)
        await (try start(model, id: id, input: scenarioWorkspaceInput(revenue: "0.0000000000000000001"))).value
        let ticket = try #require(model.valuationProposalID)
        #expect(!model.confirmValuationScenarios(proposalID: ticket, reportID: id, reportRevision: revision))
        #expect(model.valuationScenarioCalculation == nil)
        #expect(model.valuationScenarioMessage?.contains("不会补零") == true)
        #expect(await probe.sends == 1)
        #expect(await probe.keys == 1)
    }
}
