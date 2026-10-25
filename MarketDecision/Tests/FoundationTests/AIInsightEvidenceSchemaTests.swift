import Foundation
import Testing
import AIInsights

@Suite("AI request evidence schema binding")
struct AIInsightEvidenceSchemaTests {
    @Test func everyClaimUsesOnlyTheCurrentRequestsEvidenceEnum() throws {
        let value = input()
        let schema = try self.schema(AIInsightRequest(input: value))
        let definitions = try #require(schema["$defs"] as? [String: Any])
        #expect(Set(definitions.keys) == Set(["evidenceID"]))
        let definition = try #require(definitions["evidenceID"] as? [String: Any])
        #expect(definition["type"] as? String == "string")
        #expect(definition["enum"] as? [String] == ["base.revenue", "local.base"])
        let claims = try claimSchemas(schema)
        #expect(claims.count == 7)
        for claim in claims {
            #expect(claim["additionalProperties"] as? Bool == false)
            #expect(claim["required"] as? [String] == ["text", "evidenceIDs"])
            let properties = try #require(claim["properties"] as? [String: Any])
            let evidence = try #require(properties["evidenceIDs"] as? [String: Any])
            let items = try #require(evidence["items"] as? [String: String])
            #expect(items == ["$ref": "#/$defs/evidenceID"])
            #expect(evidence["minItems"] as? Int == 1)
            #expect(evidence["maxItems"] as? Int == 12)
            #expect(evidence["uniqueItems"] == nil)
        }
    }

    @Test func changedInputIDsReplaceTheEnumWithoutAddingContextPaths() throws {
        let first = input()
        let second = input(metricID: "base.revenueQuarter", sourceID: "local.growth")
        let firstIDs = try evidenceIDs(schema(AIInsightRequest(input: first)))
        let secondIDs = try evidenceIDs(schema(AIInsightRequest(input: second)))
        #expect(firstIDs == ["base.revenue", "local.base"])
        #expect(secondIDs == ["base.revenueQuarter", "local.growth"])
        #expect(Set(firstIDs).isDisjoint(with: secondIDs))
        #expect(!secondIDs.contains("metrics[0].id"))
        #expect(!secondIDs.contains("companyName") && !secondIDs.contains(second.cutoff))
        #expect(try first.digest() != second.digest())
    }

    @Test func referenceEnumContainsOnlyExplicitReferenceMetricsAndTheirFixedSource() throws {
        let basic = try evidenceIDs(schema(AIInsightRequest(input: input())))
        let reference = referenceInput()
        let scoped = try schema(AIInsightRequest(input: reference))
        let allowed = try evidenceIDs(scoped)
        let expected = reference.metrics.map(\.id) + reference.sources.map(\.id)
        #expect(allowed == expected.sorted())
        #expect(allowed.count == 9 && Set(allowed).count == 9)
        #expect(!basic.contains(where: { $0.hasPrefix("reference.") }))
        #expect(!basic.contains("local.userReference"))
        for forbidden in ["referenceValuation", "referenceAt", "sharesAsOf", "reference.targetPrice",
                          "reference.growthRate", "reference.discountRate", "reference.price.value"] {
            #expect(!allowed.contains(forbidden))
        }
        let properties = try #require(scoped["properties"] as? [String: Any])
        let valuation = try #require(properties["valuation"] as? [String: Any])
        let valuationProperties = try #require(valuation["properties"] as? [String: Any])
        let scope = try #require(valuationProperties["scope"] as? [String: Any])
        #expect(scope["enum"] as? [String] == ["referenceMultiples"])
    }

    @Test func maximumInputReusesOneEvidenceDefinitionAndKeepsRequestBudgets() throws {
        let metrics = (0..<64).map { index in
            AIInsightMetric(id: "metric-\(index)", label: "合成指标 \(index)", value: "1", unit: "USD",
                unavailable: nil, sourceIDs: ["source-0"])
        }
        let sources = (0..<64).map { AIInsightSource(id: "source-\($0)", label: "合成来源 \($0)") }
        let value = AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
            cutoff: "2026-10-22T00:00:00Z", metrics: metrics, sources: sources)
        let request = AIInsightRequest(input: value)
        let bytes = try request.encodedBody()
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let schema = try self.schema(request)
        let allowed = try evidenceIDs(schema)
        #expect(allowed.count == 128)
        // One 128-ID enum plus the one selected valuation scope, not 7 copies.
        #expect(enumValues(in: schema).count == 129)
        #expect(bytes.count <= AIInsightLimits.requestBodyBytes)
        #expect(body["max_output_tokens"] as? Int == 3_000)
        #expect(body["model"] as? String == AIInsightRequest.defaultModel)
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == false)
        for excluded in ["tools", "previous_response_id", "background", "metadata", "user"] {
            #expect(body[excluded] == nil)
        }
        let messages = try #require(body["input"] as? [[String: Any]])
        #expect(messages.count == 1)
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        let text = try #require(content.first?["text"] as? String)
        #expect(Data(text.utf8) == (try value.encoded()))
    }

    @Test func schemaCountsAndPromptDescribeTheUnchangedLocalDenialRules() throws {
        let request = AIInsightRequest(input: referenceInput())
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        let schema = try self.schema(request)
        let properties = try #require(schema["properties"] as? [String: Any])
        for name in ["strengths", "risks", "questions", "limitations"] {
            let section = try #require(properties[name] as? [String: Any])
            #expect(section["minItems"] as? Int == (name == "limitations" ? 1 : 0))
            #expect(section["maxItems"] as? Int == 6)
        }
        let valuation = try #require(properties["valuation"] as? [String: Any])
        let inner = try #require(valuation["properties"] as? [String: Any])
        let limitations = try #require(inner["limitations"] as? [String: Any])
        #expect(limitations["minItems"] as? Int == 1 && limitations["maxItems"] as? Int == 3)
        let instructions = try #require(body["instructions"] as? String)
        for instruction in ["1 至 12 个互不重复", "单段普通文字", "2000 个 UTF-8 字节",
                            "900 个 UTF-8 字节", "600 个 UTF-8 字节", "不是可引用 id",
                            "不能推测其数值", "不浏览、不调用工具", "不补造价格"] {
            #expect(instructions.contains(instruction))
        }
        #expect(AIInsightRequest.promptVersion == "financial-evidence-interpretation.v5.ps-scenarios")
        let encodedSchema = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        for unsupported in ["uniqueItems", "minLength", "maxLength", "allOf", "pattern"] {
            #expect(!encodedSchema.contains(unsupported))
        }
    }

    @Test func financialAndReferenceScopesStillAcceptCompleteCitedResponses() throws {
        for value in [input(), referenceInput()] {
            let request = AIInsightRequest(input: value)
            let scope: AIInsightValuationScope = value.referenceValuation == nil ? .financialContextOnly : .referenceMultiples
            let interpretationID = value.referenceValuation == nil ? "base.revenue" : "reference.ps"
            let sourceID = value.referenceValuation == nil ? "local.base" : "local.userReference"
            let analysis = AIInsightAnalysis(
                summary: .init(text: "这份合成资料包含收入。", evidenceIDs: ["base.revenue"]),
                strengths: [], risks: [], questions: [],
                limitations: [.init(text: "仅覆盖给定财报。", evidenceIDs: ["local.base"])],
                valuation: .init(scope: scope,
                    interpretation: .init(text: "只能结合当前证据解释参考情况。", evidenceIDs: [interpretationID]),
                    limitations: [.init(text: "缺少同业和历史比较。", evidenceIDs: [sourceID])],
                    scenarioProposal: value.supportsPriceSalesScenarios ? scenarioProposal() : nil))
            let payload = try JSONEncoder().encode(analysis)
            let envelope: [String: Any] = ["object": "response", "status": "completed",
                "model": AIInsightRequest.defaultModel, "error": NSNull(), "incomplete_details": NSNull(),
                "output": [["type": "message", "role": "assistant", "status": "completed",
                    "content": [["type": "output_text", "text": String(decoding: payload, as: UTF8.self), "annotations": []]]]]]
            let result = try request.parseResponse(JSONSerialization.data(withJSONObject: envelope))
            #expect(result.analysis == analysis)
            #expect(result.analysis.valuation.scope == scope)
            #expect(result.inputDigest == (try value.digest()))
            #expect(result.promptVersion == AIInsightRequest.promptVersion)
        }
    }

    private func scenarioProposal() -> AIPriceSalesScenarioProposal {
        let rationale = AIInsightClaim(text: "仅供用户确认的合成目标倍数假设，不是同业基准。",
                                       evidenceIDs: ["base.revenue", "reference.shares"])
        return .init(conservative: .init(multiple: "2", rationale: rationale),
                     base: .init(multiple: "3", rationale: rationale),
                     optimistic: .init(multiple: "4", rationale: rationale))
    }

    private func input(metricID: String = "base.revenue", sourceID: String = "local.base") -> AIInsightInput {
        AIInsightInput(ticker: "DEMO", companyName: "合成公司", periodEnd: "2026-09-30",
            cutoff: "2026-10-22T00:00:00.000400Z",
            metrics: [.init(id: metricID, label: "营业收入", value: "500", unit: "USD",
                            unavailable: nil, sourceIDs: [sourceID])],
            sources: [.init(id: sourceID, label: "本地合成财务计算")])
    }

    private func referenceInput() -> AIInsightInput {
        let base = input(), id = "local.userReference"
        let metrics: [AIInsightMetric] = [
            .init(id: "reference.price", label: "参考股价", value: "25", unit: "USD/share", unavailable: nil, sourceIDs: [id]),
            .init(id: "reference.shares", label: "实际股数假设", value: "100", unit: "shares", unavailable: nil, sourceIDs: [id]),
            .init(id: "reference.marketCap", label: "参考市值", value: "2500", unit: "USD", unavailable: nil, sourceIDs: [id]),
            .init(id: "reference.pe", label: "参考市盈率", value: nil, unit: "multiple", unavailable: "missingInput", sourceIDs: [id]),
            .init(id: "reference.ps", label: "参考市销率", value: "5", unit: "multiple", unavailable: nil, sourceIDs: [id]),
            .init(id: "reference.pfcf", label: "参考自由现金流倍数", value: nil, unit: "multiple", unavailable: "nonpositiveDenominator", sourceIDs: [id])]
        return AIInsightInput(ticker: base.ticker, companyName: base.companyName, periodEnd: base.periodEnd,
            cutoff: base.cutoff, metrics: base.metrics + metrics,
            sources: base.sources + [.init(id: id, label: "用户明确允许发送的参考场景")],
            referenceValuation: .init(referenceAt: "2026-10-25T00:00:00.000400Z", sharesAsOf: "2026-09-30"))
    }

    private func schema(_ request: AIInsightRequest) throws -> [String: Any] {
        let body = try #require(JSONSerialization.jsonObject(with: request.encodedBody()) as? [String: Any])
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        return try #require(format["schema"] as? [String: Any])
    }

    private func evidenceIDs(_ schema: [String: Any]) throws -> [String] {
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let definition = try #require(definitions["evidenceID"] as? [String: Any])
        return try #require(definition["enum"] as? [String])
    }

    private func claimSchemas(_ schema: [String: Any]) throws -> [[String: Any]] {
        let properties = try #require(schema["properties"] as? [String: Any])
        var result = [try #require(properties["summary"] as? [String: Any])]
        for name in ["strengths", "risks", "questions", "limitations"] {
            let section = try #require(properties[name] as? [String: Any])
            result.append(try #require(section["items"] as? [String: Any]))
        }
        let valuation = try #require(properties["valuation"] as? [String: Any])
        let inner = try #require(valuation["properties"] as? [String: Any])
        result.append(try #require(inner["interpretation"] as? [String: Any]))
        let limitations = try #require(inner["limitations"] as? [String: Any])
        result.append(try #require(limitations["items"] as? [String: Any]))
        return result
    }

    private func enumValues(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            return (object["enum"] as? [String] ?? [])
                + object.filter { $0.key != "enum" }.flatMap { enumValues(in: $0.value) }
        }
        if let array = value as? [Any] { return array.flatMap { enumValues(in: $0) } }
        return []
    }
}
