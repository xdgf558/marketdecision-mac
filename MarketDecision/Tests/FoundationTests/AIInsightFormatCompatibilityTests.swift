import Foundation
import Testing
import AIInsights
@testable import AppComposition

@Suite("AI response format compatibility and closed diagnostics")
struct AIInsightFormatCompatibilityTests {
    private let privateMarker = "Bearer SYNTHETIC-PRIVATE-MARKER https://example.invalid/?api_key=secret"

    private func request() -> AIInsightRequest {
        AIInsightRequest(input: .init(ticker: "DEMO", companyName: "合成公司",
            periodEnd: "2026-09-30", cutoff: "2026-10-29T00:00:00Z",
            metrics: [.init(id: "m-revenue", label: "收入", value: "125", unit: "USD",
                            unavailable: nil, sourceIDs: ["s-filing"])],
            sources: [.init(id: "s-filing", label: "合成财报来源")]))
    }

    private func claim(_ text: String = "只使用所提供的收入证据。") -> [String: Any] {
        ["text": text, "evidenceIDs": ["m-revenue"]]
    }

    private func analysis() -> [String: Any] {
        ["summary": claim(), "strengths": [], "risks": [], "questions": [],
         "limitations": [claim("这份摘要不构成完整分析。")],
         "valuation": ["scope": "financialContextOnly", "interpretation": claim(),
                       "limitations": [claim("尚无完整股价与股数资料。")]]]
    }

    private func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func text(_ value: [String: Any]) throws -> String {
        let data = try bytes(value)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func message(_ text: String, phase: String = "final_answer") -> [String: Any] {
        ["type": "message", "role": "assistant", "status": "completed", "phase": phase,
         "content": [["type": "output_text", "text": text, "annotations": []]]]
    }

    private func metadata() -> [[String: Any]] {
        (0..<6).map { index in
            ["type": "reasoning", "id": "SYNTHETIC-\(index)", "summary": [],
             "encrypted_content": "SYNTHETIC-ENCRYPTED-\(index)"]
        }
    }

    private func envelope(outputs: [[String: Any]]? = nil, analysis: [String: Any]? = nil) throws -> [String: Any] {
        let output = try outputs ?? [message(text(analysis ?? self.analysis()))]
        return ["object": "response", "status": "completed", "model": "gpt-6.1-sol",
                "error": NSNull(), "incomplete_details": NSNull(), "output": output,
                "usage": ["input_tokens": 320, "output_tokens": 700, "total_tokens": 1020]]
    }

    private func expectDiagnostic(_ data: Data, _ expected: AIInsightFormatIssue) throws {
        do {
            _ = try request().parseResponse(data)
            Issue.record("Malformed synthetic response unexpectedly published")
        } catch {
            #expect(error as? AIInsightError == .formatValidation(expected))
            let shown = AIInsightFailureMessage.text(for: error, stage: .requestingAnalysis)
            #expect(shown.contains("[AI-FORMAT-"))
            #expect(shown.contains("不会自动重发"))
            #expect(!shown.contains(privateMarker))
            #expect(!shown.contains("Bearer"))
            #expect(!shown.contains("example.invalid"))
            #expect(!shown.contains("api_key"))
        }
    }

    @Test func severalReasoningItemsPreserveTheUniqueFinalFinancialAnswer() throws {
        let original = try request().parseResponse(bytes(envelope()))
        let outputs = try metadata() + [message(text(analysis()))]
        #expect(outputs.count == 7)
        let actual = try request().parseResponse(bytes(envelope(outputs: outputs)))
        #expect(actual == original)
        #expect(actual.analysis.summary.evidenceIDs == ["m-revenue"])
    }

    @Test func severalCommentaryItemsAreNotMistakenForAdditionalAnswers() throws {
        var outputs = metadata()
        for index in 0..<5 {
            outputs.append(message("合成进度 \(index)", phase: "commentary"))
        }
        outputs.insert(try message(text(analysis())), at: 8)
        let actual = try request().parseResponse(bytes(envelope(outputs: outputs)))
        let original = try request().parseResponse(bytes(envelope()))
        #expect(actual == original)
    }

    @Test func moreMetadataDoesNotBypassAmbiguityTypeOrEvidenceRejection() throws {
        let final = try message(text(analysis()))
        let ambiguous = metadata() + [final, final]
        #expect(throws: AIInsightError.outputStructure(.ambiguousMessage)) {
            try request().parseResponse(bytes(envelope(outputs: ambiguous)))
        }
        let unknown = metadata() + [final, ["type": "function_call", "arguments": privateMarker]]
        #expect(throws: AIInsightError.outputStructure(.itemType)) {
            try request().parseResponse(bytes(envelope(outputs: unknown)))
        }
        var invalid = analysis()
        invalid["summary"] = ["text": "伪造引用不可通过。", "evidenceIDs": ["unprovided-source"]]
        let ungrounded = try metadata() + [message(text(invalid))]
        #expect(throws: AIInsightError.evidenceValidation(.unknownReference, section: .summary)) {
            try request().parseResponse(bytes(envelope(outputs: ungrounded)))
        }
        var badMetadata = metadata()
        badMetadata.append(["type": "reasoning", "summary": [], "encrypted_content": 12])
        #expect(throws: AIInsightError.outputStructure(.reasoningMetadata)) {
            try request().parseResponse(bytes(envelope(outputs: badMetadata + [final])))
        }
    }

    @Test func responseDiagnosticsIdentifyEnvelopeModelAndOutputWithoutReflectingPayload() throws {
        try expectDiagnostic(Data(privateMarker.utf8), .responseJSON)
        try expectDiagnostic(bytes([privateMarker]), .responseJSON)
        var wrongObject = try envelope(); wrongObject["object"] = privateMarker
        try expectDiagnostic(bytes(wrongObject), .responseEnvelope)
        var contradiction = try envelope(); contradiction["error"] = ["message": privateMarker]
        try expectDiagnostic(bytes(contradiction), .responseEnvelope)
        var wrongModel = try envelope(); wrongModel["model"] = privateMarker
        try expectDiagnostic(bytes(wrongModel), .responseModel)
        let invalidOutputs: [Any] = [[], NSNull(), [privateMarker], privateMarker]
        for output in invalidOutputs {
            var wrongOutput = try envelope(); wrongOutput["output"] = output
            try expectDiagnostic(bytes(wrongOutput), .responseOutput)
        }
    }

    @Test func answerDiagnosticsSeparateJSONShapeAndDecodingWithoutLeakingValues() throws {
        try expectDiagnostic(bytes(envelope(outputs: [message(privateMarker)])), .analysisJSON)
        var extra = analysis(); extra[privateMarker] = "unexpected"
        try expectDiagnostic(bytes(envelope(analysis: extra)), .analysisFields)
        var wrongValuation = analysis()
        wrongValuation["valuation"] = ["scope": privateMarker, "interpretation": claim(), "limitations": [claim()]]
        try expectDiagnostic(bytes(envelope(analysis: wrongValuation)), .valuationFields)
        var wrongSection = analysis(); wrongSection["risks"] = privateMarker
        try expectDiagnostic(bytes(envelope(analysis: wrongSection)), .sectionFields)
        var wrongClaim = analysis(); wrongClaim["summary"] = ["text": privateMarker, "evidenceIDs": ["m-revenue"], "order": "buy"]
        try expectDiagnostic(bytes(envelope(analysis: wrongClaim)), .claimFields)
        var wrongType = analysis(); wrongType["summary"] = ["text": [privateMarker], "evidenceIDs": ["m-revenue"]]
        try expectDiagnostic(bytes(envelope(analysis: wrongType)), .analysisDecode)
        var wrongReferences = analysis(); wrongReferences["summary"] = ["text": privateMarker, "evidenceIDs": [7]]
        try expectDiagnostic(bytes(envelope(analysis: wrongReferences)), .analysisDecode)
    }

    @Test func usageErrorsAreDistinctAndAbsentOptionalUsageRemainsCompatible() throws {
        let invalidUsage: [Any] = [privateMarker, ["input_tokens": privateMarker],
            ["input_tokens": true, "output_tokens": 1, "total_tokens": 2],
            ["input_tokens": 320, "output_tokens": 700, "total_tokens": 999]]
        for value in invalidUsage {
            var response = try envelope(); response["usage"] = value
            try expectDiagnostic(bytes(response), .usage)
        }
        var absent = try envelope(); absent.removeValue(forKey: "usage")
        #expect(try request().parseResponse(bytes(absent)).usage == nil)
        absent["usage"] = NSNull()
        #expect(try request().parseResponse(bytes(absent)).usage == nil)
        let messages = AIInsightFormatIssue.allCases.map {
            AIInsightFailureMessage.text(for: AIInsightError.formatValidation($0), stage: .requestingAnalysis)
        }
        #expect(Set(messages).count == AIInsightFormatIssue.allCases.count)
    }

    @Test func expandedMetadataRemainsBoundedByResponseAndAnalysisBudgets() throws {
        let huge = metadata() + [["type": "reasoning", "summary": [],
            "encrypted_content": String(repeating: "x", count: AIInsightLimits.responseBytes)]]
        #expect(throws: AIInsightError.budgetExceeded) {
            try request().parseResponse(bytes(envelope(outputs: huge + [message(text(analysis()))])))
        }
        let nested = "{\"x\":" + String(repeating: "[", count: 30) + "0" + String(repeating: "]", count: 30) + "}"
        #expect(throws: AIInsightError.budgetExceeded) {
            try request().parseResponse(bytes(envelope(outputs: metadata() + [message(nested)])))
        }
        #expect(throws: AIInsightError.budgetExceeded) {
            try request().parseResponse(bytes(envelope(outputs: metadata() + [message(String(repeating: "x", count: AIInsightLimits.analysisBytes + 1))])))
        }
    }
}
