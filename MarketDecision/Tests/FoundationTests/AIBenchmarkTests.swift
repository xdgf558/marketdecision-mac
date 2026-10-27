import Foundation
import Testing
import CoreDomain
import AIInsights

@Suite("AI web benchmark reference contracts")
struct AIBenchmarkTests {
    private let source = "https://fred.stlouisfed.org/series/SP500"

    private func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: text))
    }

    private func request(start: String = "2025-01-27T21:00:00Z",
                         end: String = "2026-01-27T21:00:00Z") throws -> AIBenchmarkRequest {
        AIBenchmarkRequest(start: try date(start), end: try date(end), model: "synthetic-model")
    }

    private func payload(start: String = "2025-01-27", end: String = "2026-01-27",
                         first: String = "6000", last: String = "6600") -> [String: Any] {
        ["status": "available", "index": "S&P500", "returnType": "PRICE_RETURN", "currency": "USD",
         "start": ["day": start, "close": first, "sourceURL": source],
         "end": ["day": end, "close": last, "sourceURL": source], "unavailableReason": NSNull()]
    }

    private func unavailable() -> [String: Any] {
        ["status": "unavailable", "index": "S&P500", "returnType": "PRICE_RETURN", "currency": "USD",
         "start": NSNull(), "end": NSNull(), "unavailableReason": "insufficient_evidence"]
    }

    private func bytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func search(sources: [[String: Any]]? = nil, id: String = "ws_synthetic") -> [String: Any] {
        ["id": id, "type": "web_search_call", "status": "completed",
         "action": ["type": "search", "query": "S&P 500 synthetic contract fixture",
                    "sources": sources ?? [["type": "url", "url": source, "title": "Synthetic index reference"]]]]
    }

    private func message(_ payload: [String: Any], phase: String? = nil,
                         annotations: [[String: Any]] = []) throws -> [String: Any] {
        var value: [String: Any] = ["type": "message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": String(decoding: try bytes(payload), as: UTF8.self),
                         "annotations": annotations]]]
        if let phase { value["phase"] = phase }
        return value
    }

    private func envelope(_ items: [[String: Any]]) -> [String: Any] {
        ["object": "response", "status": "completed", "model": "synthetic-model",
         "error": NSNull(), "incomplete_details": NSNull(), "output": items]
    }

    private func response(_ payload: [String: Any]? = nil) throws -> Data {
        try bytes(envelope([search(), message(payload ?? self.payload())]))
    }

    @Test func requestUsesOnlyIndexDatesAndBoundedRequiredWebSearch() throws {
        let value = try request()
        let object = try #require(JSONSerialization.jsonObject(with: value.encodedBody()) as? [String: Any])
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)
        #expect(object["tool_choice"] as? String == "required")
        #expect(object["max_tool_calls"] as? Int == 3)
        #expect(object["include"] as? [String] == ["web_search_call.action.sources"])
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search")
        let input = try #require(object["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let query = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(query.keys) == Set(["index", "returnType", "currency", "startCutoffUTC", "endCutoffUTC", "startLatestDay", "endLatestDay"]))
        #expect(query["index"] as? String == "S&P500")
        #expect(query["returnType"] as? String == "PRICE_RETURN")
        let format = try #require((object["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect(try JSONDecoder().decode(AIBenchmarkRequest.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func completedSearchProducesLocallyCalculatedBoundReference() throws {
        let value = try request(), result = try value.parseResponse(response())
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(result.request == value)
        #expect(result.unavailableReason.isEmpty)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startClose == (try Money("6000")))
        #expect(reference.endClose == (try Money("6600")))
        #expect(reference.startDay == "2025-01-27")
        #expect(reference.sources.count == 1)
        #expect(reference.startSourceURL == reference.sources[0].url)
        #expect(reference.endSourceURL == reference.sources[0].url)
        let different = AIBenchmarkRequest(start: value.start, end: value.end.addingTimeInterval(1), model: value.model)
        #expect(throws: AIBenchmarkError.invalidRequest) { try result.validate(for: different) }
    }

    @Test func unavailableSearchIsExplicitAndNeverZeroOrRemoteErrorCopy() throws {
        let value = try request(), result = try value.parseResponse(response(unavailable()))
        #expect(result.reference == nil)
        #expect(result.unavailableCode == "insufficient_evidence")
        #expect(result.unavailableReason == "未找到符合统计期间、价格指数口径与来源要求的收盘资料。")
        for code in ["not_found", "ambiguous_series"] {
            var missing = unavailable(); missing["unavailableReason"] = code
            let parsed = try value.parseResponse(response(missing))
            #expect(parsed.unavailableCode == code)
            #expect(!parsed.unavailableReason.isEmpty)
            try parsed.validate(for: value)
        }
        var injected = unavailable(); injected["unavailableReason"] = "API key secret: arbitrary remote text"
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(injected)) }
        var contradiction = unavailable(); contradiction["start"] = payload()["start"]
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(contradiction)) }
        var missing = payload(); missing["end"] = NSNull()
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(missing)) }
    }

    @Test func rejectsETFAndTotalReturnCurrencyAndInventedPercentage() throws {
        let value = try request()
        for (key, replacement) in [("index", "SPY"), ("index", "VOO"), ("index", "ES"),
                                   ("returnType", "TOTAL_RETURN"), ("currency", "EUR")] {
            var wrong = payload(); wrong[key] = replacement
            #expect(throws: AIBenchmarkError.invalidIndex) { try value.parseResponse(response(wrong)) }
        }
        var extra = payload(); extra["changePercent"] = "15"
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(extra)) }
    }

    @Test func zeroNegativeScientificAndNonDecimalClosesCannotBecomeReferences() throws {
        let value = try request()
        for close in ["0", "-1", "NaN", "6e3", "6,000", " 6000", "6000%", "9999999999", "6000.12345678901"] {
            #expect(throws: AIBenchmarkError.invalidPrice) { try value.parseResponse(response(payload(first: close))) }
        }
        let loss = try value.parseResponse(response(payload(first: "6000", last: "5400")))
        #expect(loss.reference?.changePercent == (try Money("-10")))
        let unchanged = try value.parseResponse(response(payload(first: "6000", last: "6000")))
        #expect(unchanged.reference?.changePercent == (try Money("0")))
    }

    @Test func exactNYCloseBoundaryDoesNotRoundSameDayIntoTheFuture() throws {
        let atClose = try request()
        let beforeClose = AIBenchmarkRequest(start: atClose.start, end: atClose.end.addingTimeInterval(-0.0004), model: atClose.model)
        #expect(throws: AIBenchmarkError.invalidWindow) { try beforeClose.parseResponse(response()) }
        let previous = try beforeClose.parseResponse(response(payload(end: "2026-01-26")))
        #expect(previous.reference?.endDay == "2026-01-26")
        #expect(try atClose.parseResponse(response()).reference?.endDay == "2026-01-27")
        let input = try #require(JSONSerialization.jsonObject(with: beforeClose.encodedBody()) as? [String: Any])
        let messages = try #require(input["input"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        let body = try #require(parts.first?["text"] as? String)
        #expect(body.contains("2026-01-26"))
    }

    @Test func startBoundaryAlsoRejectsLaterCloseAndDSTUsesNewYork() throws {
        let value = try request(start: "2025-07-15T19:59:59Z", end: "2026-07-15T20:00:00Z")
        #expect(throws: AIBenchmarkError.invalidWindow) {
            try value.parseResponse(response(payload(start: "2025-07-15", end: "2026-07-15")))
        }
        let allowed = try value.parseResponse(response(payload(start: "2025-07-14", end: "2026-07-15")))
        #expect(allowed.reference?.startDay == "2025-07-14")
    }

    @Test func permitsActualPriorTradingDateWithinSevenDaysButRejectsStaleAndWeekend() throws {
        let value = try request(start: "2025-01-28T21:00:00Z", end: "2026-01-28T21:00:00Z")
        let boundary = try value.parseResponse(response(payload(start: "2025-01-21", end: "2026-01-21")))
        #expect(boundary.reference?.endDay == "2026-01-21")
        for end in ["2026-01-20", "2026-01-29", "2026-01-25", "2026-02-30", "2026-1-28"] {
            #expect(throws: AIBenchmarkError.invalidWindow) { try value.parseResponse(response(payload(start: "2025-01-28", end: end))) }
        }
        #expect(throws: AIBenchmarkError.invalidWindow) {
            try value.parseResponse(response(payload(start: "2025-01-20", end: "2026-01-28")))
        }
    }

    @Test func missingIncompleteOrDuplicateSearchCannotBeReplacedByTextCitation() throws {
        let value = try request()
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([message(payload())]))) }
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([message(unavailable())]))) }
        var incomplete = search(); incomplete["status"] = "in_progress"
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([incomplete, message(payload())]))) }
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([search(), search(), message(payload())]))) }
        var root = envelope([search(), try message(payload())]); root["status"] = "incomplete"
        #expect(throws: AIBenchmarkError.incompleteResponse) { try value.parseResponse(bytes(root)) }
    }

    @Test func sourceMustAppearInThisSearchMetadataOrActualCitationAnnotation() throws {
        let value = try request()
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([search(sources: []), message(payload())])))
        }
        let citation: [String: Any] = ["type": "url_citation", "url": source, "title": "Synthetic source",
                                       "start_index": 0, "end_index": 20]
        let cited = try value.parseResponse(bytes(envelope([search(sources: []), message(payload(), annotations: [citation])])))
        #expect(cited.reference?.sources[0].url.absoluteString == source)
        var falseReference = payload()
        falseReference["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": "https://www.spglobal.com/invented"]
        #expect(throws: AIBenchmarkError.invalidEvidence) { try value.parseResponse(response(falseReference)) }
    }

    @Test func unsafeCitationsCannotPassEvenWhenSearchMetadataContainsThem() throws {
        let value = try request()
        for unsafe in ["http://fred.stlouisfed.org/series/SP500", "https://user:password@fred.stlouisfed.org/series/SP500",
                       "https://fred.stlouisfed.org:443/series/SP500", "https://127.0.0.1/index", "https://[::1]/index",
                       "https://localhost/index", "https://service.local/index", "https://fred.stlouisfed.org/series/SP500?api_key=secret",
                       "https://fred.stlouisfed.org/series/SP500#secret", "https://fred.stlouisfed.org/a b"] {
            var claim = payload(); claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": unsafe]
            let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": unsafe]]
            #expect(throws: AIBenchmarkError.invalidEvidence) {
                try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
            }
        }
        let unsafeTitle: [[String: Any]] = [["type": "url", "url": source, "title": "secret\nInjected title"]]
        let result = try value.parseResponse(bytes(envelope([search(sources: unsafeTitle), message(payload())])))
        #expect(result.reference?.sources[0].title == "fred.stlouisfed.org")
    }

    @Test func trackingOnBothSidesNormalizesAllExportedSourceURLs() throws {
        let value = try request()
        let metadataURL = source + "?utm_source=chatgpt.com&utm_medium=web&utm_campaign=benchmark&utm_term=SP500&utm_content=close"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": source + "?utm_source=chatgpt.com"]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": source + "?utm_campaign=another-campaign"]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": metadataURL, "title": "Synthetic reference"]]), message(claim)
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == source)
        #expect(reference.endSourceURL.absoluteString == source)
        #expect(reference.sources.map(\.url.absoluteString) == [source])
        #expect(reference.sources.allSatisfy { $0.url.query == nil })
    }

    @Test func trackingOnlyInMetadataMatchesUntrackedFinalSources() throws {
        let value = try request()
        let sources: [[String: Any]] = [["type": "url", "url": source + "?utm_source=chatgpt.com"]]
        let result = try value.parseResponse(bytes(envelope([search(sources: sources), message(payload())])))
        try result.validate(for: value)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        #expect(result.reference?.startSourceURL.absoluteString == source)
        #expect(result.reference?.endSourceURL.absoluteString == source)
    }

    @Test func trackingOnlyInFinalSourcesMatchesUntrackedMetadata() throws {
        let value = try request()
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": source + "?utm_source=chatgpt.com"]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": source + "?utm_medium=web"]
        let result = try value.parseResponse(response(claim))
        try result.validate(for: value)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        #expect(result.reference?.startSourceURL.absoluteString == source)
        #expect(result.reference?.endSourceURL.absoluteString == source)
    }

    @Test func trackingInActualCitationAnnotationUsesSameSourceNormalization() throws {
        let value = try request()
        let citation: [String: Any] = ["type": "url_citation", "url": source + "?utm_source=chatgpt.com",
                                       "title": "Synthetic reference", "start_index": 0, "end_index": 20]
        var claim = payload()
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": source + "?utm_content=close"]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), message(claim, annotations: [citation])
        ])))
        try result.validate(for: value)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        #expect(result.reference?.endSourceURL.absoluteString == source)
    }

    @Test func trackingCannotHideSensitiveUnknownOrResourceQueryParameters() throws {
        let value = try request()
        for query in ["api_key=secret", "api%5Fkey=secret", "access_token=secret", "signature=secret",
                      "date=2026-01-27", "symbol=SP500", "series_id=SP500", "source=other",
                      "utm_custom=unrecognized", "UTM_SOURCE=chatgpt.com"] {
            for combined in ["utm_source=chatgpt.com&" + query, query + "&utm_source=chatgpt.com"] {
                let invalidURL = source + "?" + combined
                var claim = payload()
                claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": invalidURL]
                let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": invalidURL]]
                #expect(throws: AIBenchmarkError.invalidEvidence) {
                    try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
                }
            }
        }
    }

    @Test func resourceQueriesAndDifferentPathsCannotAliasUntrackedSource() throws {
        let value = try request()
        for otherURL in [source + "?symbol=SP500&utm_source=chatgpt.com",
                         source + "?date=2026-01-27&utm_source=chatgpt.com",
                         "https://fred.stlouisfed.org/series/OTHER?utm_source=chatgpt.com"] {
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": otherURL]
            #expect(throws: AIBenchmarkError.invalidEvidence) { try value.parseResponse(response(claim)) }
            let sources: [[String: Any]] = [["type": "url", "url": otherURL]]
            #expect(throws: AIBenchmarkError.invalidEvidence) {
                try value.parseResponse(bytes(envelope([search(sources: sources), message(payload())])))
            }
        }
    }

    @Test func trackingValuesRejectEmptyControlNestedAndNonASCIIContents() throws {
        let value = try request()
        for query in ["utm_source", "utm_source=", "utm_source=%0A", "utm_source=%00", "utm_source=%E4%B8%AD",
                      "utm_source=chatgpt.com%26api_key%3Dsecret", "utm_source=web%3Btoken%3Dsecret",
                      "utm_source=%250A", "utm_source=" + String(repeating: "x", count: 257)] {
            let invalidURL = source + "?" + query
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": invalidURL]
            let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": invalidURL]]
            #expect(throws: AIBenchmarkError.invalidEvidence) {
                try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
            }
        }
    }

    @Test func trackingValuesAndQueryCountHonorClosedBudgets() throws {
        let value = try request()
        let queries = ["utm_source=" + String(repeating: "x", count: 256),
                       "utm_content=letters.ABC_123~plus+space%20hyphen-",
                       Array(repeating: "utm_source=chatgpt.com", count: 16).joined(separator: "&")]
        for query in queries {
            let trackedURL = source + "?" + query
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": trackedURL]
            let result = try value.parseResponse(response(claim))
            try result.validate(for: value)
            #expect(result.reference?.endSourceURL.absoluteString == source)
        }
        let excessiveURL = source + "?" + Array(repeating: "utm_source=chatgpt.com", count: 17).joined(separator: "&")
        var claim = payload()
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": excessiveURL]
        let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": excessiveURL]]
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
        }
    }

    @Test func reasoningAndCommentaryAreIgnoredButMultipleFinalAnswersFailClosed() throws {
        let value = try request()
        let reasoning: [String: Any] = ["type": "reasoning", "summary": [], "encrypted_content": "synthetic"]
        let root = envelope([reasoning, try message(unavailable(), phase: "commentary"), search(),
                             try message(payload(), phase: "final_answer")])
        #expect(try value.parseResponse(bytes(root)).reference?.changePercent == Money("10"))
        #expect(throws: AIBenchmarkError.ambiguousOutput) {
            try value.parseResponse(bytes(envelope([search(), message(payload()), message(payload(), phase: "final_answer")])))
        }
        var unsupported = try message(payload()); unsupported["phase"] = "analysis"
        #expect(throws: AIBenchmarkError.malformedResponse) {
            try value.parseResponse(bytes(envelope([search(), unsupported])))
        }
    }

    @Test func responseBudgetsBoundBytesDepthCollectionsSourcesAndToolCalls() throws {
        let value = try request()
        #expect(throws: AIBenchmarkError.budgetExceeded) { try value.parseResponse(Data(repeating: 32, count: 512 * 1024 + 1)) }
        let nested = "{\"nested\":" + String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25) + "}"
        #expect(throws: AIBenchmarkError.budgetExceeded) { try value.parseResponse(Data(nested.utf8)) }
        let excessive = Array(repeating: ["type": "url", "url": source] as [String: Any], count: 65)
        #expect(throws: AIBenchmarkError.budgetExceeded) {
            try value.parseResponse(bytes(envelope([search(sources: excessive), message(payload())])))
        }
        let calls = (0..<4).map { search(id: "ws_\($0)") }
        #expect(throws: AIBenchmarkError.missingSearch) {
            try value.parseResponse(bytes(envelope(calls + [message(payload())])))
        }
        var oversized = envelope([search(), try message(payload())]); oversized["unknown"] = Array(repeating: 0, count: 257)
        #expect(throws: AIBenchmarkError.budgetExceeded) { try value.parseResponse(bytes(oversized)) }
    }

    @Test func requestRejectsFutureReversedOversizedAndNonFiniteWindows() throws {
        let value = try request()
        for input in [AIBenchmarkRequest(start: value.end, end: value.start, model: value.model),
                      .init(start: value.start, end: value.start, model: value.model),
                      .init(start: value.start, end: value.start.addingTimeInterval(371 * 86_400), model: value.model),
                      .init(start: Date(), end: Date().addingTimeInterval(3600), model: value.model),
                      .init(start: Date(timeIntervalSince1970: .nan), end: value.end, model: value.model)] {
            #expect(throws: AIBenchmarkError.invalidRequest) { try input.validate() }
        }
        for model in ["", "invalid model", "gpt\n", String(repeating: "x", count: 81)] {
            #expect(throws: AIBenchmarkError.invalidModel) {
                try AIBenchmarkRequest(start: value.start, end: value.end, model: model).validate()
            }
        }
    }
}
