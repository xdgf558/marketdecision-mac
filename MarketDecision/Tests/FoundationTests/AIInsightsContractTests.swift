import Foundation
import Testing
import AIInsights

@Suite("Manual AI financial insight contracts")
struct AIInsightsContractTests {
    private func input(metrics: [AIInsightMetric]? = nil) -> AIInsightInput {
        AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
            cutoff: "2026-10-22T00:00:00.000400Z",
            metrics: metrics ?? [
                .init(id: "m-revenue", label: "营收", value: "9007199254740993.125", unit: "USD",
                      unavailable: nil, sourceIDs: ["s-filing"]),
                .init(id: "m-margin", label: "利润率", value: "0", unit: "ratio",
                      unavailable: nil, sourceIDs: ["s-filing"]),
                .init(id: "m-growth", label: "增长率", value: nil, unit: "ratio",
                      unavailable: "缺少对比期间", sourceIDs: [])
            ], sources: [.init(id: "s-filing", label: "合成财报摘要")])
    }
    private func referenceMetrics() -> [AIInsightMetric] {
        [
            .init(id: "reference.price", label: "用户参考价", value: "25", unit: "USD/share", unavailable: nil, sourceIDs: ["local.userReference"]),
            .init(id: "reference.shares", label: "用户确认单一普通股股数", value: "100", unit: "shares", unavailable: nil, sourceIDs: ["local.userReference"]),
            .init(id: "reference.marketCap", label: "本地参考市值", value: "2500", unit: "USD", unavailable: nil, sourceIDs: ["local.userReference"]),
            .init(id: "reference.pe", label: "参考市盈率", value: "10", unit: "multiple", unavailable: nil, sourceIDs: ["local.userReference"]),
            .init(id: "reference.ps", label: "参考市销率", value: "5", unit: "multiple", unavailable: nil, sourceIDs: ["local.userReference"]),
            .init(id: "reference.pfcf", label: "参考市现率", value: nil, unit: "multiple", unavailable: "nonpositiveDenominator", sourceIDs: ["local.userReference"])
        ]
    }
    private func referenceInput(metrics: [AIInsightMetric]? = nil,
                                context: AIInsightReferenceValuationContext? = .init(
                                    referenceAt: "2026-10-25T12:00:00.000400Z", sharesAsOf: "2026-09-30"),
                                cutoff: String? = nil) -> AIInsightInput {
        let base = input()
        return AIInsightInput(ticker: base.ticker, companyName: base.companyName, periodEnd: base.periodEnd,
            cutoff: cutoff ?? base.cutoff, metrics: base.metrics + (metrics ?? referenceMetrics()),
            sources: base.sources + [.init(id: "local.userReference", label: "用户允许发送的参考输入；本地倍数计算，非认证市场报价")],
            referenceValuation: context)
    }
    private func referenceAnalysis() -> [String: Any] {
        var value = analysis()
        value["valuation"] = ["scope": "referenceMultiples",
            "interpretation": ["text": "参考市盈率为10倍，但缺少比较基准，不能仅凭这一数值判断高低估。", "evidenceIDs": ["reference.pe"]],
            "limitations": [["text": "用户提供价格与股数，且自由现金流倍数仍缺少正分母，不是认证行情或合理价结论。", "evidenceIDs": ["local.userReference", "reference.pfcf"]]]]
        return value
    }
    private func analysis() -> [String: Any] {
        ["summary": ["text": "这份合成摘要提供了营收与利润率。", "evidenceIDs": ["m-revenue", "m-margin"]],
         "strengths": [], "risks": [],
         "questions": [["text": "仍需补齐增长率的对比期间。", "evidenceIDs": ["m-growth"]]],
         "limitations": [["text": "仅覆盖提供的财报摘要，不含当前价格。", "evidenceIDs": ["s-filing"]]],
         "valuation": valuation()]
    }
    private func valuation() -> [String: Any] {
        ["scope": "financialContextOnly",
         "interpretation": ["text": "当前营收证据可用于理解经营规模，但增长对价值的支持仍缺对比资料。",
                            "evidenceIDs": ["m-revenue", "m-growth"]],
         "limitations": [["text": "摘要不含当前股价、完整股本和估值假设，无法判断价格贵贱。",
                          "evidenceIDs": ["s-filing"]]]]
    }
    private func responseObject(analysis: [String: Any]? = nil) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: analysis ?? self.analysis(), options: [.sortedKeys])
        let text = try #require(String(data: data, encoding: .utf8))
        return ["object": "response", "status": "completed", "model": "gpt-6-luna-2026-10-01",
                "error": NSNull(), "incomplete_details": NSNull(),
                "output": [["type": "message", "role": "assistant", "status": "completed",
                            "content": [["type": "output_text", "text": text, "annotations": []]]]],
                "usage": ["input_tokens": 200, "output_tokens": 100, "total_tokens": 300]]
    }
    private func bytes(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func message(_ fragments: [String], phase: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["type": "message", "role": "assistant", "status": "completed",
            "content": fragments.map { ["type": "output_text", "text": $0, "annotations": []] as [String: Any] }]
        if let phase { value["phase"] = phase }
        return value
    }
    private func analysisText(_ value: [String: Any]? = nil) throws -> String {
        let encoded = try bytes(value ?? analysis())
        return try #require(String(data: encoded, encoding: .utf8))
    }

    @Test func exactDecimalZeroMissingAndCutoffSurviveSummaryEncoding() throws {
        let original = input(), data = try original.encoded()
        let roundTrip = try JSONDecoder().decode(AIInsightInput.self, from: data)
        #expect(roundTrip == original)
        #expect(roundTrip.metrics[0].value == "9007199254740993.125")
        #expect(roundTrip.metrics[1].value == "0")
        #expect(roundTrip.metrics[2].value == nil)
        #expect(roundTrip.metrics[2].unavailable == "缺少对比期间")
        #expect(roundTrip.cutoff == "2026-10-22T00:00:00.000400Z")
        #expect(try roundTrip.digest() == original.digest())
    }

    @Test func inputRejectsMissingStateContradictionsAndUntraceableNumericValues() throws {
        for metric in [
            AIInsightMetric(id: "m-a", label: "A", value: nil, unit: "USD", unavailable: nil, sourceIDs: []),
            .init(id: "m-a", label: "A", value: "0", unit: "USD", unavailable: "缺失", sourceIDs: ["s-filing"]),
            .init(id: "m-a", label: "A", value: "3", unit: "USD", unavailable: nil, sourceIDs: []),
            .init(id: "m-a", label: "A", value: "3", unit: "USD", unavailable: nil, sourceIDs: ["invented"]),
            .init(id: "m-a", label: "A", value: "NaN", unit: "USD", unavailable: nil, sourceIDs: ["s-filing"])
        ] {
            #expect(throws: AIInsightError.invalidInput) { try input(metrics: [metric]).validate() }
        }
    }

    @Test func identifierCollisionsCannotChangeMeaningOfGeneratedCitations() throws {
        let duplicate = input().metrics[0]
        #expect(throws: AIInsightError.invalidInput) { try input(metrics: [duplicate, duplicate]).validate() }
        let shadowSource = AIInsightMetric(id: "s-filing", label: "冒充来源", value: "1", unit: "USD",
                                          unavailable: nil, sourceIDs: ["s-filing"])
        #expect(throws: AIInsightError.invalidInput) { try input(metrics: [shadowSource]).validate() }
    }

    @Test func outboundBodyContainsOnlySummaryAndExplicitNonStoredNonStreamingRequest() throws {
        let request = AIInsightRequest(input: input())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(Set(body.keys) == Set(["model", "reasoning", "store", "stream", "max_output_tokens", "instructions", "input", "text"]))
        #expect(body["model"] as? String == "gpt-6.1-sol")
        #expect(body["reasoning"] as? [String: String] == ["effort": "max"])
        #expect(body["max_output_tokens"] as? Int == 3_000)
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["input"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let summary = try #require(content.first?["text"] as? String)
        let decoded = try JSONDecoder().decode(AIInsightInput.self, from: Data(summary.utf8))
        #expect(decoded == input())
        let object = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(["format", "ticker", "companyName", "periodEnd", "cutoff", "metrics", "sources"]))
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect(format["type"] as? String == "json_schema")
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("不可信数据"))
        #expect(instructions.contains("不把缺失当成零"))
    }

    @Test func storedModelUpgradeRunsOnceAndPreservesCustomChoices() throws {
        let initialChoices: [String?] = [nil, "gpt-6-luna", "custom-model"]
        for initial in initialChoices {
            let suiteName = "local.marketdecision.tests.ai-model-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            if let initial { defaults.set(initial, forKey: AIModelConfiguration.modelPreferenceKey) }
            defaults.set("preserved", forKey: "unrelated-setting")

            AIModelConfiguration.migrateStoredModel(in: defaults)
            let expected = initial == "custom-model" ? "custom-model" : "gpt-6.1-sol"
            #expect(defaults.string(forKey: AIModelConfiguration.modelPreferenceKey) == expected)
            AIModelConfiguration.migrateStoredModel(in: defaults)
            #expect(defaults.string(forKey: AIModelConfiguration.modelPreferenceKey) == expected)
            #expect(defaults.string(forKey: "unrelated-setting") == "preserved")

            // A later deliberate user choice must survive subsequent launches,
            // even when that choice is the old default model.
            defaults.set("gpt-6-luna", forKey: AIModelConfiguration.modelPreferenceKey)
            AIModelConfiguration.migrateStoredModel(in: defaults)
            #expect(defaults.string(forKey: AIModelConfiguration.modelPreferenceKey) == "gpt-6-luna")
        }
    }

    @Test func customModelsKeepTheirOriginalRequestBudgetWithoutForcedReasoning() throws {
        for model in ["gpt-6-luna", "custom-model", "gpt-6.1-sol-custom"] {
            let request = AIInsightRequest(input: input(), model: model)
            let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
            #expect(body["model"] as? String == model)
            #expect(body["reasoning"] == nil)
            #expect(body["max_output_tokens"] as? Int == 3_000)
            #expect(body["store"] as? Bool == false && body["stream"] as? Bool == false)
            #expect(body["tools"] == nil)
            #expect(try JSONDecoder().decode(AIInsightRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }

    @Test func completedResponseBindsActualModelAndExactInputWithEvidence() throws {
        let request = AIInsightRequest(input: input())
        let result = try request.parseResponse(bytes(responseObject()))
        #expect(result.inputDigest == (try input().digest()))
        #expect(result.requestedModel == AIInsightRequest.defaultModel)
        #expect(result.model == "gpt-6-luna-2026-10-01")
        #expect(result.analysis.questions.first?.evidenceIDs == ["m-growth"])
        #expect(result.analysis.valuation.scope == .financialContextOnly)
        #expect(result.analysis.valuation.interpretation.evidenceIDs == ["m-revenue", "m-growth"])
        #expect(result.usage == AIInsightUsage(inputTokens: 200, outputTokens: 100, totalTokens: 300))
        #expect(result.promptVersion == AIInsightRequest.promptVersion)
    }

    // New valuation coverage is regression source only; no tests are executed in this batch.
    @Test func oneRequestRequiresBoundedFinancialContextValuationWithoutExtraInputFields() throws {
        let request = AIInsightRequest(input: input())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == 3_000)
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.count == 1)
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("valuation") == true)
        let properties = try #require(schema["properties"] as? [String: Any])
        let valuationSchema = try #require(properties["valuation"] as? [String: Any])
        #expect(valuationSchema["additionalProperties"] as? Bool == false)
        #expect(Set(valuationSchema["required"] as? [String] ?? []) == Set(["scope", "interpretation", "limitations"]))
        let valuationProperties = try #require(valuationSchema["properties"] as? [String: Any])
        let scope = try #require(valuationProperties["scope"] as? [String: Any])
        #expect(scope["enum"] as? [String] == ["financialContextOnly"])
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("若输入没有 referenceValuation"))
        #expect(instructions.contains("缺项时也须返回此对象"))
        let result = try request.parseResponse(bytes(responseObject()))
        #expect(result.promptVersion == "financial-evidence-interpretation.v5.ps-scenarios")
        #expect(try JSONDecoder().decode(AIInsightResult.self, from: JSONEncoder().encode(result)) == result)
        try result.analysis.validate(for: input())
    }

    @Test func valuationMissingEvidenceRemainsExplicitAndCitationsCannotBeInvented() throws {
        let request = AIInsightRequest(input: input())
        let result = try request.parseResponse(bytes(responseObject()))
        #expect(input().metrics.first { $0.id == "m-growth" }?.value == nil)
        #expect(result.analysis.valuation.interpretation.evidenceIDs.contains("m-growth"))
        #expect(result.analysis.valuation.limitations.first?.text.contains("不含当前股价") == true)
        for key in ["interpretation", "limitations"] {
            for (citations, issue) in [(["unprovided-price"], AIInsightEvidenceIssue.unknownReference),
                                      ([], .missingReferences), (["m-revenue", "m-revenue"], .duplicateReferences)] {
                var generated = analysis(), value = valuation()
                let claim: [String: Any] = ["text": "引用必须来自原摘要。", "evidenceIDs": citations]
                if key == "interpretation" { value[key] = claim }
                else { value[key] = [claim] }
                generated["valuation"] = value
                let section: AIInsightClaimSection = key == "interpretation" ? .valuationInterpretation : .valuationLimitations
                #expect(throws: AIInsightError.evidenceValidation(issue, section: section)) {
                    try request.parseResponse(bytes(responseObject(analysis: generated)))
                }
            }
        }
    }

    @Test func missingNullOrUnknownValuationFieldsCannotSilentlyUpgradeLegacyAnalysis() throws {
        let request = AIInsightRequest(input: input())
        var missing = analysis(); missing.removeValue(forKey: "valuation")
        var null = analysis(); null["valuation"] = NSNull()
        var targetPrice = valuation(); targetPrice["targetPrice"] = "999"
        var badScope = valuation(); badScope["scope"] = "fairValueEstimate"
        var noReasons = valuation(); noReasons["limitations"] = []
        var noInterpretation = valuation(); noInterpretation.removeValue(forKey: "interpretation")
        var extraClaimField = valuation()
        extraClaimField["interpretation"] = ["text": "不接受额外字段。", "evidenceIDs": ["m-revenue"], "rating": "buy"]
        var cases = [missing, null]
        for value in [targetPrice, badScope, noReasons, noInterpretation, extraClaimField] {
            var generated = analysis(); generated["valuation"] = value; cases.append(generated)
        }
        for generated in cases {
            #expect(throws: AIInsightError.malformedResponse) {
                try request.parseResponse(bytes(responseObject(analysis: generated)))
            }
        }
    }

    @Test func valuationCompactBudgetsAndLimitationsApplyToPublicValidationToo() throws {
        let request = AIInsightRequest(input: input())
        var tooMany = valuation()
        tooMany["limitations"] = Array(repeating: ["text": "缺少证据。", "evidenceIDs": ["s-filing"]] as [String: Any], count: 4)
        var generated = analysis(); generated["valuation"] = tooMany
        #expect(throws: AIInsightError.malformedResponse) {
            try request.parseResponse(bytes(responseObject(analysis: generated)))
        }
        for (key, text) in [("interpretation", String(repeating: "界", count: 301)),
                            ("limitations", String(repeating: "x", count: 601))] {
            var value = valuation()
            let claim: [String: Any] = ["text": text, "evidenceIDs": ["m-revenue"]]
            if key == "interpretation" { value[key] = claim }
            else { value[key] = [claim] }
            var generated = analysis(); generated["valuation"] = value
            let section: AIInsightClaimSection = key == "interpretation" ? .valuationInterpretation : .valuationLimitations
            #expect(throws: AIInsightError.evidenceValidation(.textTooLong, section: section)) {
                try request.parseResponse(bytes(responseObject(analysis: generated)))
            }
        }
        let parsed = try request.parseResponse(bytes(responseObject())).analysis
        let bad = AIInsightAnalysis(summary: parsed.summary, strengths: parsed.strengths, risks: parsed.risks,
            questions: parsed.questions, limitations: parsed.limitations,
            valuation: .init(interpretation: .init(text: "无效引用。", evidenceIDs: ["invented"]),
                             limitations: parsed.valuation.limitations))
        #expect(throws: AIInsightError.evidenceValidation(.unknownReference, section: .valuationInterpretation)) { try bad.validate(for: input()) }
    }

    // User-reference additions remain source-only until a separately authorized execution.
    @Test func userReferenceContextRequiresLocalExactCapitalAndClosedMetricSet() throws {
        let original = referenceInput()
        try original.validate()
        #expect(original.format == "ai-financial-summary.v2")
        #expect(try JSONDecoder().decode(AIInsightInput.self, from: original.encoded()) == original)
        #expect(throws: AIInsightError.invalidInput) { try referenceInput(context: nil).validate() }
        #expect(throws: AIInsightError.invalidInput) { try referenceInput(metrics: Array(referenceMetrics().dropLast())).validate() }
        for (id, unit, sources) in [("reference.targetPrice", "USD/share", ["local.userReference"]),
                                    ("reference.price", "USD", ["local.userReference"]),
                                    ("reference.price", "USD/share", ["s-filing"])] {
            var metrics = referenceMetrics()
            metrics[0] = .init(id: id, label: "错误参考类型", value: "25", unit: unit, unavailable: nil, sourceIDs: sources)
            #expect(throws: AIInsightError.invalidInput) { try referenceInput(metrics: metrics).validate() }
        }
    }

    @Test func userReferencePricesSharesAndRatiosRejectInvalidValuesWithoutZeroFallback() throws {
        for (index, value) in [(0, "0"), (0, "-1"), (1, "0.5"), (1, "0"), (2, "2501"), (3, "0"), (4, "-1")] {
            var metrics = referenceMetrics(); let original = metrics[index]
            metrics[index] = .init(id: original.id, label: original.label, value: value, unit: original.unit,
                                   unavailable: nil, sourceIDs: original.sourceIDs)
            #expect(throws: AIInsightError.invalidInput) { try referenceInput(metrics: metrics).validate() }
        }
        let missing = try #require(referenceInput().metrics.first { $0.id == "reference.pfcf" })
        #expect(missing.value == nil && missing.unavailable == "nonpositiveDenominator")
        var metrics = referenceMetrics()
        metrics[5] = .init(id: missing.id, label: missing.label, value: nil, unit: missing.unit,
                           unavailable: nil, sourceIDs: missing.sourceIDs)
        #expect(throws: AIInsightError.invalidInput) { try referenceInput(metrics: metrics).validate() }
    }

    @Test func referenceContextFixedPolicyAndDatesCannotBeOverriddenByDecodedData() throws {
        let original = try #require(referenceInput().referenceValuation)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for (key, value) in [("method", "automatic-dcf"), ("sourceID", "alpaca.iex"), ("basis", "unreviewed"),
                             ("origin", "providerCapture"), ("referenceAt", "2026-10-25T12:00:00+08:00"),
                             ("sharesAsOf", "2026-10-26"), ("sharesAsOf", "2026-02-30"), ("rawSource", "not allowed")] {
            var changed = object; changed[key] = value
            #expect(throws: AIInsightError.invalidInput) {
                try JSONDecoder().decode(AIInsightReferenceValuationContext.self, from: bytes(changed))
            }
        }
        var missing = object; missing.removeValue(forKey: "origin")
        #expect(throws: AIInsightError.invalidInput) {
            try JSONDecoder().decode(AIInsightReferenceValuationContext.self, from: bytes(missing))
        }
        for referenceAt in ["2026-10-21T23:59:59.999999999Z", "2026-10-22T00:00:00Z",
                            "2026-10-22T00:00:00.000399999Z"] {
            let early = referenceInput(context: .init(referenceAt: referenceAt, sharesAsOf: "2026-09-30"))
            // Decoding a packet cannot bypass the same exact cutoff rule as the local adapter.
            let decoded = try JSONDecoder().decode(AIInsightInput.self, from: JSONEncoder().encode(early))
            #expect(throws: AIInsightError.invalidInput) { try decoded.validate() }
            #expect(throws: AIInsightError.invalidInput) { try AIInsightRequest(input: decoded).encodedBody() }
        }
        for referenceAt in ["2026-10-22T00:00:00.0004Z", "2026-10-22T00:00:00.000400000Z",
                            "2026-10-22T00:00:00.000400001Z"] {
            try referenceInput(context: .init(referenceAt: referenceAt, sharesAsOf: "2026-09-30")).validate()
        }
        try referenceInput(context: .init(referenceAt: "2026-10-22T00:00:00Z", sharesAsOf: "2026-09-30"),
                           cutoff: "2026-10-22T00:00:00.000000000Z").validate()
        try referenceInput(context: .init(referenceAt: "2026-10-22T00:00:00.000000000Z", sharesAsOf: "2026-09-30"),
                           cutoff: "2026-10-22T00:00:00Z").validate()
    }

    @Test func referenceRequestBindsContextPrecisionAndUsesOnlyItsExpectedResponseScope() throws {
        let summary = referenceInput(), request = AIInsightRequest(input: summary)
        let result = try request.parseResponse(bytes(responseObject(analysis: referenceAnalysis())))
        #expect(result.analysis.valuation.scope == .referenceMultiples)
        #expect(result.inputDigest == (try summary.digest()))
        #expect(summary.referenceValuation?.referenceAt == "2026-10-25T12:00:00.000400Z")
        #expect(throws: AIInsightError.malformedResponse) { try request.parseResponse(bytes(responseObject())) }
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: input()).parseResponse(bytes(responseObject(analysis: referenceAnalysis())))
        }
        let different = referenceInput(context: .init(referenceAt: "2026-10-25T12:00:00.000401Z", sharesAsOf: "2026-09-30"))
        #expect(try different.digest() != summary.digest())
    }

    @Test func referenceRequestKeepsOneRequestBudgetAndNoTargetsOrAssumptionPayload() throws {
        let request = AIInsightRequest(input: referenceInput())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == 3_000)
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == false)
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.count == 1)
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let payload = try #require(content.first?["text"] as? String)
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(["format", "ticker", "companyName", "periodEnd", "cutoff", "metrics", "sources", "referenceValuation"]))
        let context = try #require(object["referenceValuation"] as? [String: Any])
        #expect(Set(context.keys) == Set(["method", "sourceID", "basis", "origin", "referenceAt", "sharesAsOf"]))
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("已提供的价格、股数或方法不能再笼统说成"))
        #expect(instructions.contains("不能仅凭倍数判断高估"))
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        let valuation = try #require(props["valuation"] as? [String: Any])
        let valuationProps = try #require(valuation["properties"] as? [String: Any])
        let scope = try #require(valuationProps["scope"] as? [String: Any])
        #expect(scope["enum"] as? [String] == ["referenceMultiples"])
    }

    @Test func referenceValuationCannotCiteAbsentInputsOrAddTargetPriceFields() throws {
        let request = AIInsightRequest(input: referenceInput())
        var invalid = referenceAnalysis()
        var valuation = try #require(invalid["valuation"] as? [String: Any])
        valuation["interpretation"] = ["text": "不能引用没有提供的目标倍数。", "evidenceIDs": ["reference.targetMultiple"]]
        invalid["valuation"] = valuation
        #expect(throws: AIInsightError.evidenceValidation(.unknownReference, section: .valuationInterpretation)) { try request.parseResponse(bytes(responseObject(analysis: invalid))) }
        valuation["targetPrice"] = "99"
        invalid["valuation"] = valuation
        #expect(throws: AIInsightError.malformedResponse) { try request.parseResponse(bytes(responseObject(analysis: invalid))) }
    }

    @Test func fabricatedOrEmptyEvidenceCannotBePresentedAsGroundedAnalysis() throws {
        for (citations, issue) in [(["unknown-source"], AIInsightEvidenceIssue.unknownReference),
                                  ([], .missingReferences), (["m-revenue", "m-revenue"], .duplicateReferences)] {
            var generated = analysis()
            generated["summary"] = ["text": "看似合理但引用错误。", "evidenceIDs": citations]
            #expect(throws: AIInsightError.evidenceValidation(issue, section: .summary)) {
                try AIInsightRequest(input: input()).parseResponse(bytes(responseObject(analysis: generated)))
            }
        }
    }

    @Test func incompleteAndFailedResponsesCannotPublishPartialJSON() throws {
        for status in ["incomplete", "cancelled", "in_progress", "queued"] {
            var envelope = try responseObject(); envelope["status"] = status
            #expect(throws: AIInsightError.incompleteResponse) {
                try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
            }
        }
        var failed = try responseObject(); failed["status"] = "failed"
        failed["error"] = ["code": "server_error", "message": "Bearer synthetic-secret"]
        #expect(throws: AIInsightError.responseFailed) {
            try AIInsightRequest(input: input()).parseResponse(bytes(failed))
        }
        var contradictory = try responseObject(); contradictory["error"] = ["code": "server_error"]
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: input()).parseResponse(bytes(contradictory))
        }
    }

    @Test func incompleteReasonsDistinguishOutputLimitAndFilteringWithoutPublishingOutput() throws {
        let reasons: [(String, AIInsightError)] = [
            ("max_output_tokens", .outputLimitReached), ("content_filter", .contentFiltered)]
        for (reason, expected) in reasons {
            // Even a complete-looking analysis inside an incomplete envelope stays unusable.
            var envelope = try responseObject(); envelope["status"] = "incomplete"
            envelope["incomplete_details"] = ["reason": reason, "message": "Bearer synthetic-private-text"]
            #expect(throws: expected) {
                try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
            }
            // Reasons have meaning only for incomplete responses. They do not relax the
            // completed-response contract or replace a different lifecycle status.
            envelope["status"] = "completed"
            #expect(throws: AIInsightError.malformedResponse) {
                try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
            }
            envelope["status"] = "failed"
            #expect(throws: AIInsightError.responseFailed) {
                try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
            }
            envelope["status"] = "in_progress"
            #expect(throws: AIInsightError.incompleteResponse) {
                try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
            }
        }
    }

    @Test func unknownIncompleteReasonsRemainClosedAndDoNotChangeRequestBudget() throws {
        let details: [Any] = [
            NSNull(), "max_output_tokens", ["reason": NSNull()], ["reason": 7],
            ["reason": "MAX_OUTPUT_TOKENS"], ["reason": "Bearer synthetic-secret"],
            ["reason": "unknown_future_reason", "message": "content_filter"],
            ["reason": String(repeating: "x", count: 500)]]
        let request = AIInsightRequest(input: input())
        for detail in details {
            var envelope = try responseObject(); envelope["status"] = "incomplete"
            envelope["incomplete_details"] = detail
            #expect(throws: AIInsightError.incompleteResponse) { try request.parseResponse(bytes(envelope)) }
        }
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(body["max_output_tokens"] as? Int == 3_000)
        #expect(body["model"] as? String == AIInsightRequest.defaultModel)
    }

    @Test func refusalAndToolOutputsAreNeverParsedAsAnalysis() throws {
        var refusal = try responseObject()
        refusal["output"] = [["type": "message", "role": "assistant", "status": "completed",
                              "content": [["type": "refusal", "refusal": "Cannot comply"]]]]
        #expect(throws: AIInsightError.refused) {
            try AIInsightRequest(input: input()).parseResponse(bytes(refusal))
        }
        var tool = try responseObject()
        tool["output"] = [["type": "function_call", "name": "send_credentials", "arguments": "{}"]]
        #expect(throws: AIInsightError.outputStructure(.itemType)) {
            try AIInsightRequest(input: input()).parseResponse(bytes(tool))
        }
    }

    @Test func reasoningMetadataMayBeIgnoredButCannotSupplyOrSubstituteAnalysis() throws {
        var envelope = try responseObject()
        let outputs = try #require(envelope["output"] as? [[String: Any]])
        envelope["output"] = [["type": "reasoning", "summary": []]] + outputs
        #expect(try AIInsightRequest(input: input()).parseResponse(bytes(envelope)).analysis.risks.isEmpty)
        envelope["output"] = [["type": "reasoning", "summary": []]]
        #expect(throws: AIInsightError.outputStructure(.missingText)) {
            try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
        }
    }

    // Regression source only: this batch is NOT_EXECUTED at the user's request.
    @Test func nonStoredResponseDiscardsEncryptedReasoningWithoutChangingFinancialResult() throws {
        let request = AIInsightRequest(input: input())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        let expected = try request.parseResponse(bytes(responseObject()))
        var envelope = try responseObject()
        envelope["output"] = [
            ["type": "reasoning", "id": "rs-synthetic-metadata", "summary": [],
             "encrypted_content": "SYNTHETIC-ENCRYPTED-REASONING-NOT-FINANCIAL-DATA", "status": "completed"],
            message([try analysisText()])]
        let actual = try request.parseResponse(bytes(envelope))
        #expect(actual == expected)
        let encoded = try #require(String(data: JSONEncoder().encode(actual), encoding: .utf8))
        #expect(!encoded.contains("SYNTHETIC-ENCRYPTED-REASONING"))
        #expect(!encoded.contains("rs-synthetic-metadata"))
    }

    @Test func reasoningSummaryIsMetadataAndCannotIntroduceFinancialEvidence() throws {
        let metadata: [String: Any] = ["type": "reasoning",
            "summary": [["type": "summary_text", "text": "SYNTHETIC-REASONING-SUMMARY m-invented"]],
            "encrypted_content": NSNull()]
        let request = AIInsightRequest(input: input())
        var envelope = try responseObject()
        envelope["output"] = [metadata, message([try analysisText()])]
        let result = try request.parseResponse(bytes(envelope))
        let encoded = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
        #expect(!encoded.contains("SYNTHETIC-REASONING-SUMMARY"))
        var invented = analysis()
        invented["summary"] = ["text": "不能把推理元信息变成财报依据。", "evidenceIDs": ["m-invented"]]
        envelope["output"] = [metadata, message([try analysisText(invented)])]
        #expect(throws: AIInsightError.evidenceValidation(.unknownReference, section: .summary)) { try request.parseResponse(bytes(envelope)) }
        envelope["output"] = [metadata]
        #expect(throws: AIInsightError.outputStructure(.missingText)) { try request.parseResponse(bytes(envelope)) }
    }

    @Test func finalTextFragmentsJoinInOrderUnderOneCumulativeUTF8Budget() throws {
        let request = AIInsightRequest(input: input()), text = try analysisText()
        let split = text.index(text.startIndex, offsetBy: text.count / 2)
        var envelope = try responseObject()
        envelope["output"] = [message([String(text[..<split]), String(text[split...])], phase: "final_answer")]
        #expect(try request.parseResponse(bytes(envelope)) == request.parseResponse(bytes(responseObject())))
        // JSON whitespace is permitted; this exactly reaches the byte budget.
        let padding = String(repeating: " ", count: AIInsightLimits.analysisBytes - text.utf8.count)
        envelope["output"] = [message([padding, text])]
        #expect(try request.parseResponse(bytes(envelope)).analysis == request.parseResponse(bytes(responseObject())).analysis)
        // Each block is below the limit, but the Chinese character adds three bytes
        // when only two remain. The budget must be checked before JSON decoding.
        let almostFull = String(repeating: " ", count: AIInsightLimits.analysisBytes - 2 - text.utf8.count)
        envelope["output"] = [message([almostFull, text, "界"])]
        #expect(throws: AIInsightError.budgetExceeded) { try request.parseResponse(bytes(envelope)) }
    }

    @Test func commentaryCannotReplaceOrContaminateTheSingleFinalFinancialMessage() throws {
        let request = AIInsightRequest(input: input()), final = message([try analysisText()], phase: "final_answer")
        let commentary = message(["SYNTHETIC-COMMENTARY-IS-NOT-JSON"], phase: "commentary")
        for outputs in [[commentary, final], [final, commentary]] {
            var envelope = try responseObject(); envelope["output"] = outputs
            let result = try request.parseResponse(bytes(envelope))
            #expect(result == (try request.parseResponse(bytes(responseObject()))))
            let encoded = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))
            #expect(!encoded.contains("SYNTHETIC-COMMENTARY"))
        }
        var envelope = try responseObject(); envelope["output"] = [commentary]
        #expect(throws: AIInsightError.outputStructure(.missingText)) { try request.parseResponse(bytes(envelope)) }
    }

    @Test func multipleFinalOrUnlabelledMessagesRemainAmbiguous() throws {
        let request = AIInsightRequest(input: input()), text = try analysisText()
        let explicit = message([text], phase: "final_answer"), legacy = message([text])
        var nullPhase = legacy; nullPhase["phase"] = NSNull()
        for outputs in [[explicit, explicit], [legacy, legacy], [explicit, legacy], [nullPhase, explicit]] {
            var envelope = try responseObject(); envelope["output"] = outputs
            #expect(throws: AIInsightError.outputStructure(.ambiguousMessage)) {
                try request.parseResponse(bytes(envelope))
            }
        }
        var envelope = try responseObject(); envelope["output"] = [nullPhase]
        #expect(try request.parseResponse(bytes(envelope)) == request.parseResponse(bytes(responseObject())))
    }

    @Test func unknownPhasesToolsRefusalsAndExternalAnnotationsStayRejected() throws {
        let request = AIInsightRequest(input: input()), final = message([try analysisText()], phase: "final_answer")
        for kind in ["function_call", "web_search_call", "unknown_future_output"] {
            var envelope = try responseObject(); envelope["output"] = [["type": kind], final]
            #expect(throws: AIInsightError.outputStructure(.itemType)) { try request.parseResponse(bytes(envelope)) }
        }
        let invalidPhases: [Any] = ["unknown_future_phase", 7]
        for rawPhase in invalidPhases {
            var invalid = final; invalid["phase"] = rawPhase
            var envelope = try responseObject(); envelope["output"] = [invalid]
            #expect(throws: AIInsightError.outputStructure(.messagePhase)) { try request.parseResponse(bytes(envelope)) }
        }
        for phase in ["commentary", "final_answer"] {
            var refusal = message([], phase: phase)
            refusal["content"] = [["type": "refusal", "refusal": "SYNTHETIC-PRIVATE-REFUSAL"]]
            var envelope = try responseObject(); envelope["output"] = [refusal, final]
            #expect(throws: AIInsightError.refused) { try request.parseResponse(bytes(envelope)) }
            let invalidAnnotations: [Any] = [NSNull(), "invalid", [["type": "url_citation", "url": "https://example.invalid/synthetic"]]]
            for annotations in invalidAnnotations {
                var annotated = message([], phase: phase)
                annotated["content"] = [["type": "output_text", "text": "not evidence", "annotations": annotations]]
                envelope["output"] = [annotated, final]
                #expect(throws: AIInsightError.outputStructure(.annotations)) { try request.parseResponse(bytes(envelope)) }
            }
            var missing = message([], phase: phase)
            missing["content"] = [["type": "output_text", "text": "missing annotations"]]
            envelope["output"] = [missing, final]
            #expect(throws: AIInsightError.outputStructure(.annotations)) { try request.parseResponse(bytes(envelope)) }
        }
    }

    @Test func malformedReasoningMetadataDoesNotBecomeAnIgnoredEscapeHatch() throws {
        let request = AIInsightRequest(input: input()), final = message([try analysisText()])
        let malformed: [[String: Any]] = [
            ["type": "reasoning"], ["type": "reasoning", "summary": NSNull()],
            ["type": "reasoning", "summary": ["not a summary object"]],
            ["type": "reasoning", "summary": [["type": "unknown", "text": "ignored"]]],
            ["type": "reasoning", "summary": [["type": "summary_text", "text": 7]]],
            ["type": "reasoning", "summary": [], "encrypted_content": 7],
            ["type": "reasoning", "summary": [], "encrypted_content": ["unexpected": "object"]],
            ["type": "reasoning", "summary": [], "status": "in_progress"]]
        for metadata in malformed {
            var envelope = try responseObject(); envelope["output"] = [metadata, final]
            #expect(throws: AIInsightError.outputStructure(.reasoningMetadata)) {
                try request.parseResponse(bytes(envelope))
            }
        }
    }

    @Test func compatibleResponseWrappingDoesNotRelaxFinancialShapeOrCitationChecks() throws {
        let request = AIInsightRequest(input: input())
        let metadata: [String: Any] = ["type": "reasoning", "summary": [], "encrypted_content": "SYNTHETIC-ENCRYPTED"]
        var wrongEvidence = analysis()
        wrongEvidence["summary"] = ["text": "错误引用仍须拒绝。", "evidenceIDs": ["s-not-in-input"]]
        var extra = analysis(); extra["order"] = ["side": "buy", "quantity": 100]
        var noLimitations = analysis(); noLimitations["limitations"] = []
        let cases: [([String: Any], AIInsightError)] = [
            (wrongEvidence, .evidenceValidation(.unknownReference, section: .summary)), (extra, .malformedResponse), (noLimitations, .malformedResponse)]
        for (generated, expected) in cases {
            let text = try analysisText(generated), split = text.index(text.startIndex, offsetBy: text.count / 2)
            var envelope = try responseObject()
            envelope["output"] = [metadata, message(["只有最终消息是分析。"], phase: "commentary"),
                message([String(text[..<split]), String(text[split...])], phase: "final_answer")]
            #expect(throws: expected) { try request.parseResponse(bytes(envelope)) }
        }
    }

    @Test func additionalRecommendationsAndMissingLimitationsAreRejected() throws {
        var extra = analysis(); extra["order"] = ["side": "buy", "quantity": 100]
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: input()).parseResponse(bytes(responseObject(analysis: extra)))
        }
        var missing = analysis(); missing["limitations"] = []
        #expect(throws: AIInsightError.malformedResponse) {
            try AIInsightRequest(input: input()).parseResponse(bytes(responseObject(analysis: missing)))
        }
    }

    @Test func responseByteAndNestingBudgetsRejectBeforeDecodingAnalysis() throws {
        let request = AIInsightRequest(input: input())
        #expect(throws: AIInsightError.budgetExceeded) {
            try request.parseResponse(Data(repeating: 32, count: AIInsightLimits.responseBytes + 1))
        }
        let nested = "{\"x\":" + String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30) + "}"
        #expect(throws: AIInsightError.budgetExceeded) { try request.parseResponse(Data(nested.utf8)) }
        var oversized = analysis()
        oversized["summary"] = ["text": String(repeating: "x", count: 2_001), "evidenceIDs": ["m-revenue"]]
        #expect(throws: AIInsightError.evidenceValidation(.textTooLong, section: .summary)) { try request.parseResponse(bytes(responseObject(analysis: oversized))) }
    }

    private func replacingEvidenceClaim(_ claim: [String: Any], section: AIInsightClaimSection) throws -> [String: Any] {
        var value = analysis()
        switch section {
        case .valuationAssumptions:
            // The separate scenario suite covers this conditional section with eligible inputs.
            throw AIInsightError.scenarioProposal(.ineligibleInput)
        case .summary: value["summary"] = claim
        case .strengths, .risks, .questions, .limitations: value[section.rawValue] = [claim]
        case .valuationInterpretation, .valuationLimitations:
            var nested = try #require(value["valuation"] as? [String: Any])
            if section == .valuationInterpretation { nested["interpretation"] = claim }
            else { nested["limitations"] = [claim] }
            value["valuation"] = nested
        }
        return value
    }

    @Test func evidenceDiagnosticReasonsAndSectionsApplyToParserAndPublicValidation() throws {
        let request = AIInsightRequest(input: input())
        for section in AIInsightClaimSection.allCases where section != .valuationAssumptions {
            let limit = section == .valuationInterpretation ? 900 : (section == .valuationLimitations ? 600 : 2_000)
            let cases: [(String, [String], AIInsightEvidenceIssue)] = [
                (" \t ", ["m-revenue"], .emptyText),
                (String(repeating: "x", count: limit + 1), ["m-revenue"], .textTooLong),
                ("非空正文\n第二行", ["m-revenue"], .controlCharacter),
                ("缺少引用。", [], .missingReferences),
                ("引用过多。", Array(repeating: "m-revenue", count: 13), .tooManyReferences),
                ("引用重复。", ["m-revenue", "m-revenue"], .duplicateReferences),
                ("未知引用。", ["SYNTHETIC-PRIVATE-EVIDENCE"], .unknownReference)
            ]
            for (text, citations, reason) in cases {
                let value = try replacingEvidenceClaim(["text": text, "evidenceIDs": citations], section: section)
                let expected = AIInsightError.evidenceValidation(reason, section: section)
                #expect(throws: expected) { try request.parseResponse(bytes(responseObject(analysis: value))) }
                let decoded = try JSONDecoder().decode(AIInsightAnalysis.self, from: bytes(value))
                #expect(throws: expected) { try decoded.validate(for: input()) }
            }
        }
    }

    @Test func evidenceDiagnosticsKeepExactUTF8AndTwelveUniqueReferenceBoundaries() throws {
        let base = input()
        let references = (0..<13).map { AIInsightSource(id: "source-boundary-\($0)", label: "合成边界资料") }
        let extended = AIInsightInput(ticker: base.ticker, companyName: base.companyName, periodEnd: base.periodEnd,
            cutoff: base.cutoff, metrics: base.metrics, sources: base.sources + references)
        let request = AIInsightRequest(input: extended)
        let twelve = Array(references.prefix(12).map(\.id))
        for section in AIInsightClaimSection.allCases where section != .valuationAssumptions {
            let limit = section == .valuationInterpretation ? 900 : (section == .valuationLimitations ? 600 : 2_000)
            let exact = String(repeating: "界", count: limit / 3) + String(repeating: "x", count: limit % 3)
            #expect(exact.utf8.count == limit)
            let accepted = try replacingEvidenceClaim(["text": exact, "evidenceIDs": twelve], section: section)
            _ = try request.parseResponse(bytes(responseObject(analysis: accepted)))
            let decoded = try JSONDecoder().decode(AIInsightAnalysis.self, from: bytes(accepted))
            try decoded.validate(for: extended)
            let longer = try replacingEvidenceClaim(["text": exact + "x", "evidenceIDs": twelve], section: section)
            #expect(throws: AIInsightError.evidenceValidation(.textTooLong, section: section)) {
                try request.parseResponse(bytes(responseObject(analysis: longer)))
            }
            let excessive = try replacingEvidenceClaim(["text": "十三项合法但过多的引用。", "evidenceIDs": references.map(\.id)], section: section)
            #expect(throws: AIInsightError.evidenceValidation(.tooManyReferences, section: section)) {
                try request.parseResponse(bytes(responseObject(analysis: excessive)))
            }
        }
    }

    @Test func inputBudgetsAndModelValidationRejectBeforeRequestEncoding() throws {
        let source = input().metrics[0]
        let tooMany = (0..<65).map { index in
            AIInsightMetric(id: "m-\(index)", label: source.label, value: source.value, unit: source.unit,
                            unavailable: nil, sourceIDs: source.sourceIDs)
        }
        #expect(throws: AIInsightError.invalidInput) { try AIInsightRequest(input: input(metrics: tooMany)).encodedBody() }
        #expect(throws: AIInsightError.invalidModel) { try AIInsightRequest(input: input(), model: "model\nBearer secret").encodedBody() }
    }

    @Test func usageCannotMasqueradeAsBooleanOrHideInconsistentTokenCounts() throws {
        let invalidUsage: [[String: Any]] = [
            ["input_tokens": true, "output_tokens": 100, "total_tokens": 101],
            ["input_tokens": 200, "output_tokens": 100, "total_tokens": 299],
            ["input_tokens": -1, "output_tokens": 100, "total_tokens": 99]
        ]
        for usage in invalidUsage {
            var response = try responseObject(); response["usage"] = usage
            #expect(throws: AIInsightError.malformedResponse) {
                try AIInsightRequest(input: input()).parseResponse(bytes(response))
            }
        }
    }
}
