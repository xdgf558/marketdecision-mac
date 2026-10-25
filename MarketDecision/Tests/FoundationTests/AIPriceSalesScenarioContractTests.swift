import Foundation
import Testing
import AIInsights

@Suite("AI price sales scenario proposal contract")
struct AIPriceSalesScenarioContractTests {
    private func input(revenue: String? = "500", revenueID: String = "base.revenue",
                       revenueUnit: String = "USD", revenueSource: String = "local.base",
                       reference: Bool = true) -> AIInsightInput {
        let local = AIInsightReferenceValuationContext.referenceSourceID
        var metrics: [AIInsightMetric] = [.init(id: revenueID, label: "TTM 收入", value: revenue,
            unit: revenueUnit, unavailable: revenue == nil ? "missingInput" : nil, sourceIDs: [revenueSource])]
        var sources = [AIInsightSource(id: revenueSource, label: "合成本地收入计算")]
        if reference {
            metrics += [
                .init(id: "reference.price", label: "用户参考价", value: "25", unit: "USD/share", unavailable: nil, sourceIDs: [local]),
                .init(id: "reference.shares", label: "用户确认股数", value: "100", unit: "shares", unavailable: nil, sourceIDs: [local]),
                .init(id: "reference.marketCap", label: "参考市值", value: "2500", unit: "USD", unavailable: nil, sourceIDs: [local]),
                .init(id: "reference.pe", label: "市盈率", value: nil, unit: "multiple", unavailable: "missingInput", sourceIDs: [local]),
                .init(id: "reference.ps", label: "市销率", value: "5", unit: "multiple", unavailable: nil, sourceIDs: [local]),
                .init(id: "reference.pfcf", label: "市现率", value: nil, unit: "multiple", unavailable: "nonpositiveDenominator", sourceIDs: [local])]
            sources.append(.init(id: local, label: "合成手工参考输入"))
        }
        return AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
            cutoff: "2026-10-22T00:00:00Z", metrics: metrics, sources: sources,
            referenceValuation: reference ? .init(referenceAt: "2026-10-25T00:00:00Z", sharesAsOf: "2026-09-30") : nil)
    }

    private func proposal(_ multiples: [String] = ["2", "3", "4"],
                          method: String = AIPriceSalesScenarioProposal.currentMethod,
                          text: String = "这是待用户确认的目标倍数假设，不是财报事实或同业基准。",
                          ids: [String] = ["base.revenue", "reference.shares"]) throws -> AIPriceSalesScenarioProposal {
        try #require(multiples.count == 3)
        let reason = AIInsightClaim(text: text, evidenceIDs: ids)
        return .init(method: method,
            conservative: .init(multiple: multiples[0], rationale: reason),
            base: .init(multiple: multiples[1], rationale: reason),
            optimistic: .init(multiple: multiples[2], rationale: reason))
    }

    private func analysis(proposal: AIPriceSalesScenarioProposal?, reference: Bool = true) -> AIInsightAnalysis {
        let claim = AIInsightClaim(text: "仅解读本次提供的财务资料。", evidenceIDs: ["base.revenue"])
        return .init(summary: claim, strengths: [], risks: [], questions: [], limitations: [claim],
            valuation: .init(scope: reference ? .referenceMultiples : .financialContextOnly,
                interpretation: claim, limitations: [claim], scenarioProposal: proposal))
    }

    private func response(_ analysis: [String: Any]) throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: analysis), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["object": "response", "status": "completed",
            "model": AIInsightRequest.defaultModel,
            "output": [["type": "message", "role": "assistant", "status": "completed",
                "content": [["type": "output_text", "text": content, "annotations": []]]]]])
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func valuationSchema(_ input: AIInsightInput) throws -> [String: Any] {
        let body = try #require(JSONSerialization.jsonObject(with: AIInsightRequest(input: input).encodedBody()) as? [String: Any])
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        return try #require(properties["valuation"] as? [String: Any])
    }

    @Test func scenarioSchemaRequiresProposalOnlyForReplayedPositiveTTMRevenueAndReferenceShares() throws {
        let eligible = input()
        try eligible.validate()
        #expect(eligible.supportsPriceSalesScenarios)
        let schema = try valuationSchema(eligible)
        #expect((schema["required"] as? [String])?.contains("scenarioProposal") == true)
        let properties = try #require(schema["properties"] as? [String: Any])
        let proposal = try #require(properties["scenarioProposal"] as? [String: Any])
        #expect(proposal["additionalProperties"] as? Bool == false)
        #expect(Set(proposal["required"] as? [String] ?? []) == Set(["method", "conservative", "base", "optimistic"]))
        for ineligible in [input(revenue: nil), input(revenue: "0"), input(revenue: "-1"),
                           input(revenueID: "growth.revenueQuarter"), input(revenueUnit: "USD/share"),
                           input(revenueSource: "other.source"), input(reference: false)] {
            try ineligible.validate()
            #expect(!ineligible.supportsPriceSalesScenarios)
            let other = try valuationSchema(ineligible)
            let props = try #require(other["properties"] as? [String: Any])
            #expect(props["scenarioProposal"] == nil)
            #expect((other["required"] as? [String])?.contains("scenarioProposal") == false)
        }
    }

    @Test func validScenarioProposalRoundTripsAndBindsTheSameInputWithoutReturningPrices() throws {
        let input = input(), proposal = try proposal()
        let value = analysis(proposal: proposal)
        try value.validate(for: input)
        let decoded = try JSONDecoder().decode(AIPriceSalesScenarioProposal.self, from: JSONEncoder().encode(proposal))
        #expect(decoded == proposal)
        let result = try AIInsightRequest(input: input).parseResponse(response(object(value)))
        #expect(result.analysis == value)
        #expect(result.inputDigest == (try input.digest()))
        #expect(result.promptVersion == "financial-evidence-interpretation.v5.ps-scenarios")
        let encoded = try object(proposal)
        #expect(Set(encoded.keys) == Set(["method", "conservative", "base", "optimistic"]))
        for name in ["conservative", "base", "optimistic"] {
            let row = try #require(encoded[name] as? [String: Any])
            #expect(Set(row.keys) == Set(["multiple", "rationale"]))
        }
    }

    @Test func missingOrUnexpectedScenarioCannotBypassDirectOrParsedValidation() throws {
        let missing = analysis(proposal: nil)
        #expect(throws: AIInsightError.scenarioProposal(.missingProposal)) { try missing.validate(for: input()) }
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: input()).parseResponse(response(object(missing)))
        }
        let unqualified = input(revenue: nil)
        let supplied = analysis(proposal: try proposal())
        #expect(throws: AIInsightError.scenarioProposal(.ineligibleInput)) { try supplied.validate(for: unqualified) }
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: unqualified).parseResponse(response(object(supplied)))
        }
    }

    @Test func scenarioMultiplesRejectInvalidDecimalOrderingAndUnknownMethods() throws {
        for bad in ["0", "-1", "1e1", "NaN", "Infinity", " 2", "2×", "+2", String(repeating: "1", count: 161)] {
            let value = try proposal([bad, "3", "4"])
            #expect(throws: AIInsightError.scenarioProposal(.invalidMultiple)) { try value.validate(for: input()) }
        }
        for unordered in [["2", "2", "4"], ["3", "2", "4"], ["2", "4", "3"]] {
            #expect(throws: AIInsightError.scenarioProposal(.unorderedMultiples)) {
                try proposal(unordered).validate(for: input())
            }
        }
        #expect(throws: AIInsightError.scenarioProposal(.unsupportedMethod)) {
            try proposal(method: "automatic-dcf").validate(for: input())
        }
        // No unapproved valuation ceiling; these are representable assumptions, not endorsement.
        try proposal(["200.125", "300.25", "400.5"]).validate(for: input())
    }

    @Test func scenarioRationalesRetainClosedEvidenceAndExactTextBudgets() throws {
        let cases: [(String, [String], AIInsightEvidenceIssue)] = [
            (" ", ["base.revenue", "reference.shares"], .emptyText),
            (String(repeating: "界", count: 200) + "x", ["base.revenue", "reference.shares"], .textTooLong),
            ("假设\n第二行", ["base.revenue", "reference.shares"], .controlCharacter),
            ("假设", [], .missingReferences),
            ("假设", Array(repeating: "base.revenue", count: 13), .tooManyReferences),
            ("假设", ["base.revenue", "base.revenue", "reference.shares"], .duplicateReferences),
            ("假设", ["base.revenue", "reference.shares", "private-unknown"], .unknownReference)]
        for (text, ids, issue) in cases {
            let value = try proposal(text: text, ids: ids)
            let error = AIInsightError.evidenceValidation(issue, section: .valuationAssumptions)
            #expect(throws: error) { try value.validate(for: input()) }
            #expect(throws: error) {
                try AIInsightRequest(input: input()).parseResponse(response(object(analysis(proposal: value))))
            }
        }
        try proposal(text: String(repeating: "界", count: 200)).validate(for: input())
        for ids in [["base.revenue"], ["reference.shares"], ["local.base", "local.userReference"]] {
            #expect(throws: AIInsightError.scenarioProposal(.missingBasisReferences)) {
                try proposal(ids: ids).validate(for: input())
            }
        }
    }

    @Test func scenarioDecoderRejectsExtraOrMissingFieldsAtEveryProposalLevel() throws {
        let original = try object(proposal())
        var extra = original; extra["price"] = "12"
        var missing = original; missing.removeValue(forKey: "optimistic")
        var rowExtra = original
        var base = try #require(original["base"] as? [String: Any]); base["price"] = "15"; rowExtra["base"] = base
        var reasonExtra = original
        var row = try #require(original["base"] as? [String: Any])
        var reason = try #require(row["rationale"] as? [String: Any]); reason["url"] = "https://invalid.example"
        row["rationale"] = reason; reasonExtra["base"] = row
        for invalid in [extra, missing, rowExtra, reasonExtra] {
            let data = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: AIInsightError.malformedResponse) {
                try JSONDecoder().decode(AIPriceSalesScenarioProposal.self, from: data)
            }
            var generated = try object(analysis(proposal: try proposal()))
            var valuation = try #require(generated["valuation"] as? [String: Any])
            valuation["scenarioProposal"] = invalid; generated["valuation"] = valuation
            #expect(throws: AIInsightError.malformedResponse) {
                try AIInsightRequest(input: input()).parseResponse(response(generated))
            }
        }
    }

    @Test func scenarioRequestKeepsOneRequestBudgetAndExplicitUnconfirmedAssumptions() throws {
        let request = AIInsightRequest(input: input())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == 3_000)
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == false)
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.count == 1)
        let prompt = try #require(body["instructions"] as? String)
        for phrase in ["尚待用户确认", "不从当前 reference.ps 循环反推", "不输出或另算任何价格", "不能补造或使用单季度收入替代"] {
            #expect(prompt.contains(phrase))
        }
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        for unsupported in ["uniqueItems", "minLength", "maxLength", "allOf", "pattern"] { #expect(!encoded.contains(unsupported)) }
        let definitions = try #require(schema["$defs"] as? [String: Any])
        #expect(Set(definitions.keys) == Set(["evidenceID"]))
    }
}
