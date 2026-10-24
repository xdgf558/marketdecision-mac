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
    private func analysis() -> [String: Any] {
        ["summary": ["text": "这份合成摘要提供了营收与利润率。", "evidenceIDs": ["m-revenue", "m-margin"]],
         "strengths": [], "risks": [],
         "questions": [["text": "仍需补齐增长率的对比期间。", "evidenceIDs": ["m-growth"]]],
         "limitations": [["text": "仅覆盖提供的财报摘要，不含当前价格。", "evidenceIDs": ["s-filing"]]]]
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
        #expect(Set(body.keys) == Set(["model", "store", "stream", "max_output_tokens", "instructions", "input", "text"]))
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

    @Test func completedResponseBindsActualModelAndExactInputWithEvidence() throws {
        let request = AIInsightRequest(input: input())
        let result = try request.parseResponse(bytes(responseObject()))
        #expect(result.inputDigest == (try input().digest()))
        #expect(result.requestedModel == AIInsightRequest.defaultModel)
        #expect(result.model == "gpt-6-luna-2026-10-01")
        #expect(result.analysis.questions.first?.evidenceIDs == ["m-growth"])
        #expect(result.usage == AIInsightUsage(inputTokens: 200, outputTokens: 100, totalTokens: 300))
        #expect(result.promptVersion == AIInsightRequest.promptVersion)
    }

    @Test func fabricatedOrEmptyEvidenceCannotBePresentedAsGroundedAnalysis() throws {
        for citations in [["unknown-source"], [], ["m-revenue", "m-revenue"]] {
            var generated = analysis()
            generated["summary"] = ["text": "看似合理但引用错误。", "evidenceIDs": citations]
            #expect(throws: AIInsightError.invalidEvidence) {
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
        #expect(throws: AIInsightError.unexpectedOutput) {
            try AIInsightRequest(input: input()).parseResponse(bytes(tool))
        }
    }

    @Test func reasoningMetadataMayBeIgnoredButCannotSupplyOrSubstituteAnalysis() throws {
        var envelope = try responseObject()
        let outputs = try #require(envelope["output"] as? [[String: Any]])
        envelope["output"] = [["type": "reasoning", "summary": []]] + outputs
        #expect(try AIInsightRequest(input: input()).parseResponse(bytes(envelope)).analysis.risks.isEmpty)
        envelope["output"] = [["type": "reasoning", "summary": []]]
        #expect(throws: AIInsightError.unexpectedOutput) {
            try AIInsightRequest(input: input()).parseResponse(bytes(envelope))
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
        #expect(throws: AIInsightError.invalidEvidence) { try request.parseResponse(bytes(responseObject(analysis: oversized))) }
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
