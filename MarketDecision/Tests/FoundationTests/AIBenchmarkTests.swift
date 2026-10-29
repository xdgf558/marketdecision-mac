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
         "start": ["day": start, "close": first],
         "end": ["day": end, "close": last], "unavailableReason": NSNull()]
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

    private func pageAction(_ type: String, url: Any?, status: String = "completed") -> [String: Any] {
        var action: [String: Any] = ["type": type]
        if let url { action["url"] = url }
        if type == "find_in_page" { action["pattern"] = "synthetic close" }
        return ["id": "ws_page_synthetic", "type": "web_search_call", "status": status, "action": action]
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
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let optionalPoint = try #require(properties["start"] as? [String: Any])
        let alternatives = try #require(optionalPoint["anyOf"] as? [[String: Any]])
        let point = try #require(alternatives.first)
        #expect(point["required"] as? [String] == ["day", "close"])
        let pointProperties = try #require(point["properties"] as? [String: Any])
        #expect(Set(pointProperties.keys) == ["day", "close"])
        #expect(try JSONDecoder().decode(AIBenchmarkRequest.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func solBenchmarkRequestUsesMaxWithoutChangingSearchOrOutputBudgets() throws {
        let original = try request()
        let upgraded = AIBenchmarkRequest(start: original.start, end: original.end,
            model: AIInsightRequest.defaultModel)
        var body = try #require(JSONSerialization.jsonObject(with: upgraded.encodedBody()) as? [String: Any])
        #expect(body["model"] as? String == "gpt-6.1-sol")
        #expect(body["reasoning"] as? [String: String] == ["effort": "max"])
        #expect(body["max_output_tokens"] as? Int == 2_000)
        #expect(body["max_tool_calls"] as? Int == 3)
        #expect(try JSONDecoder().decode(AIBenchmarkRequest.self, from: JSONEncoder().encode(upgraded)) == upgraded)
        body.removeValue(forKey: "reasoning")
        body.removeValue(forKey: "model")
        let comparable = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        for model in ["gpt-6-luna", "synthetic-model", "gpt-6.1-sol-custom"] {
            let custom = AIBenchmarkRequest(start: original.start, end: original.end, model: model)
            var customBody = try #require(JSONSerialization.jsonObject(with: custom.encodedBody()) as? [String: Any])
            #expect(customBody["model"] as? String == model)
            #expect(customBody["reasoning"] == nil)
            customBody.removeValue(forKey: "model")
            #expect(try JSONSerialization.data(withJSONObject: customBody, options: [.sortedKeys]) == comparable)
        }
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
        #expect(reference.sourceKind == .searchSources)
        #expect(reference.sources[0].url.absoluteString == source)
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
        #expect(throws: AIBenchmarkError.missingSearch) {
            try value.parseResponse(bytes(envelope([message(payload(), annotations: [citation(source)])])))
        }
        var incomplete = search(); incomplete["status"] = "in_progress"
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([incomplete, message(payload())]))) }
        #expect(throws: AIBenchmarkError.missingSearch) { try value.parseResponse(bytes(envelope([search(), search(), message(payload())]))) }
        var root = envelope([search(), try message(payload())]); root["status"] = "incomplete"
        #expect(throws: AIBenchmarkError.incompleteResponse) { try value.parseResponse(bytes(root)) }
    }

    private func citation(_ url: String, title: String = "Synthetic citation") -> [String: Any] {
        ["type": "url_citation", "url": url, "title": title, "start_index": 0, "end_index": 20]
    }

    private func metadata(_ urls: [String]) -> [[String: Any]] {
        urls.map { ["type": "url", "url": $0] }
    }

    @Test func responseMetadataRequiredAndModelAuthoredSourceURLsAreRefused() throws {
        let value = try request()
        #expect(throws: AIBenchmarkError.missingSourceMetadata) {
            try value.parseResponse(bytes(envelope([search(sources: []), message(payload())])))
        }
        var invented = payload()
        invented["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": "https://www.spglobal.com/invented"]
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(invented)) }
        invented = payload(); invented["sources"] = [source]
        #expect(throws: AIBenchmarkError.malformedResponse) { try value.parseResponse(response(invented)) }
    }

    @Test func finalCitationsTakePriorityWithoutRepeatingSearchURLs() throws {
        let value = try request()
        let cited = source + "?symbol=SP500&date=2026-01-27#history"
        let result = try value.parseResponse(bytes(envelope([
            search(), message(payload(), phase: "final_answer", annotations: [citation(cited)])
        ])))
        try result.validate(for: value)
        #expect(result.reference?.sourceKind == .answerCitations)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [cited])
        #expect(result.reference?.changePercent == (try Money("10")))
        let unphased = try value.parseResponse(bytes(envelope([
            search(sources: []), message(payload(), annotations: [citation(cited)])
        ])))
        #expect(unphased.reference?.sourceKind == .answerCitations)
    }

    @Test func commentaryCitationsNeverBecomeAnswerOrSearchSources() throws {
        let value = try request(), commentaryURL = source + "#commentary"
        let commentary = try message(unavailable(), phase: "commentary", annotations: [citation(commentaryURL)])
        let result = try value.parseResponse(bytes(envelope([search(), commentary, message(payload())])))
        #expect(result.reference?.sourceKind == .searchSources)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        #expect(throws: AIBenchmarkError.missingSourceMetadata) {
            try value.parseResponse(bytes(envelope([search(sources: []), commentary, message(payload())])))
        }
    }

    @Test func unsafeFinalCitationsFallBackToSearchSourcesWithoutRelabeling() throws {
        let value = try request()
        let unsafe = citation(source + "?api_key=secret")
        let result = try value.parseResponse(bytes(envelope([search(), message(payload(), annotations: [unsafe])])))
        #expect(result.reference?.sourceKind == .searchSources)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        #expect(throws: AIBenchmarkError.missingSourceMetadata) {
            try value.parseResponse(bytes(envelope([search(sources: []), message(payload(), annotations: [unsafe])])))
        }
        let cited = source + "#valid-citation"
        let mixed = try value.parseResponse(bytes(envelope([
            search(), message(payload(), annotations: [unsafe, citation(cited)])
        ])))
        #expect(mixed.reference?.sourceKind == .answerCitations)
        #expect(mixed.reference?.sources.map(\.url.absoluteString) == [cited])
    }

    @Test func sourceListsDeduplicateInFirstSeenOrder() throws {
        let value = try request(), second = source + "#second"
        let citations = [citation(second, title: "First title"), citation(source), citation(second, title: "Later title")]
        let result = try value.parseResponse(bytes(envelope([search(), message(payload(), annotations: citations)])))
        #expect(result.reference?.sources.map(\.url.absoluteString) == [second, source])
        #expect(result.reference?.sources.first?.title == "First title")
        let searched = try value.parseResponse(bytes(envelope([
            search(sources: metadata([second, source, second])), message(payload())
        ])))
        #expect(searched.reference?.sources.map(\.url.absoluteString) == [second, source])
    }

    @Test func completedOpenPageURLSuppliesSourceWithoutSourcesOrAnnotations() throws {
        let value = try request()
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), pageAction("open_page", url: source), message(payload())
        ])))
        #expect(result.reference?.sourceKind == .searchSources)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
    }

    @Test func completedFindInPageURLSuppliesSourceWithoutSourcesOrAnnotations() throws {
        let value = try request()
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), pageAction("find_in_page", url: source), message(payload())
        ])))
        #expect(result.reference?.sourceKind == .searchSources)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
    }

    @Test func optionalOpenPageURLDoesNotInvalidateOtherValidSources() throws {
        let value = try request()
        for action in [pageAction("open_page", url: nil), pageAction("open_page", url: NSNull())] {
            let result = try value.parseResponse(bytes(envelope([search(), action, message(payload())])))
            #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
            #expect(throws: AIBenchmarkError.missingSourceMetadata) {
                try value.parseResponse(bytes(envelope([search(sources: []), action, message(payload())])))
            }
        }
    }

    @Test func pageActionStillRequiresCompletedSearchAndCompletedVisit() throws {
        let value = try request()
        for type in ["open_page", "find_in_page"] {
            #expect(throws: AIBenchmarkError.missingSearch) {
                try value.parseResponse(bytes(envelope([pageAction(type, url: source), message(payload())])))
            }
            #expect(throws: AIBenchmarkError.missingSearch) {
                try value.parseResponse(bytes(envelope([
                    search(), pageAction(type, url: source, status: "in_progress"), message(payload())
                ])))
            }
        }
    }

    @Test func pageActionSourcesPreserveDifferentPathsWithoutClaimingPriceBinding() throws {
        let value = try request(), visited = "https://www.spglobal.com/spdji/en/indices/equity/sp-500/"
        for type in ["open_page", "find_in_page"] {
            let result = try value.parseResponse(bytes(envelope([
                search(), pageAction(type, url: visited), message(payload())
            ])))
            #expect(result.reference?.sourceKind == .searchSources)
            #expect(result.reference?.sources.map(\.url.absoluteString) == [source, visited])
        }
    }

    @Test func unsafePageActionURLCannotPolluteValidReference() throws {
        let value = try request()
        for type in ["open_page", "find_in_page"] {
            let action = pageAction(type, url: source + "?access_token=secret")
            let result = try value.parseResponse(bytes(envelope([search(), action, message(payload())])))
            #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
            #expect(throws: AIBenchmarkError.missingSourceMetadata) {
                try value.parseResponse(bytes(envelope([search(sources: []), action, message(payload())])))
            }
        }
    }

    @Test func pageActionURLSharesSourceBudgetAndRejectsMalformedMetadata() throws {
        let value = try request()
        let sixtyFour = metadata(Array(repeating: source, count: 64))
        let atLimit = try value.parseResponse(bytes(envelope([
            search(sources: sixtyFour, id: "ws_first"),
            search(sources: Array(sixtyFour.dropLast()), id: "ws_second"),
            pageAction("open_page", url: source), message(payload())
        ])))
        #expect(atLimit.reference?.sources.count == 1)
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([
                search(sources: sixtyFour, id: "ws_first"), search(sources: sixtyFour, id: "ws_second"),
                pageAction("open_page", url: source), message(payload())
            ])))
        }
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([search(), pageAction("open_page", url: 123), message(payload())])))
        }
    }

    @Test func unsafeSourceURLsAreFilteredWithoutReplacingTheirContents() throws {
        let value = try request()
        let unsafe = ["http://fred.stlouisfed.org/series/SP500", "javascript:alert(1)", "file:///tmp/data",
                      "https://user:password@fred.stlouisfed.org/series/SP500", "https://127.0.0.1/index",
                      "https://[::1]/index", "https://localhost/index", "https://service.local/index",
                      "https://service.internal/index", "https://service.invalid/index", "https://fred.stlouisfed.org/a b"]
        for url in unsafe {
            let result = try value.parseResponse(bytes(envelope([
                search(sources: metadata([url, source])), message(payload())
            ])))
            #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
            #expect(throws: AIBenchmarkError.missingSourceMetadata) {
                try value.parseResponse(bytes(envelope([search(sources: metadata([url])), message(payload())])))
            }
        }
        let standardPort = "https://fred.stlouisfed.org:443/series/SP500"
        let accepted = try value.parseResponse(bytes(envelope([
            search(sources: metadata([standardPort])), message(payload())
        ])))
        #expect(accepted.reference?.sources.first?.url.absoluteString == standardPort)
    }

    @Test func invalidSourceTitlesFallBackToHost() throws {
        let result = try request().parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": source, "title": "Injected\nremote text"]]), message(payload())
        ])))
        #expect(result.reference?.sources.first?.title == "fred.stlouisfed.org")
    }

    @Test func resourceQueriesRemainDisplayLinksWithoutTypedInterpretation() throws {
        let value = try request()
        let queries = ["symbol=%5EGSPC&date=2026-01-27&utm_source=chatgpt.com", "DATE=2026-02-29&custom=monthly",
                       "symbol=SP500&symbol=SP500", "period1=-1&interval=1h", "from=2026/01/27&filter=adjusted",
                       "q=S%26P%20500&empty=&flag", "url=https%3A%2F%2Ffred.stlouisfed.org%2Fseries%2FSP500",
                       "symbol=%255EGSPC", "date=2026-01-27T21:00:00Z"]
        for query in queries {
            let url = source + "?" + query
            let result = try value.parseResponse(bytes(envelope([search(sources: metadata([url])), message(payload())])))
            try result.validate(for: value)
            #expect(result.reference?.sources.map(\.url.absoluteString) == [url])
            #expect(result.reference?.changePercent == (try Money("10")))
        }
    }

    @Test func resourceQueryOrderAndPresenceRemainDistinctDisplayLinks() throws {
        let urls = [source + "?date=2026-01-27&symbol=SP500", source + "?symbol=SP500&date=2026-01-27",
                    source + "?date=2026-01-27", source]
        let result = try request().parseResponse(bytes(envelope([search(sources: metadata(urls)), message(payload())])))
        #expect(result.reference?.sources.map(\.url.absoluteString) == urls)
        #expect(result.reference?.sourceKind == .searchSources)
    }

    @Test func resourceSelectorsDoNotOverrideIndexOrPriceDateValidation() throws {
        let value = try request()
        let sources = metadata([source + "?date=2026-01-27&symbol=SP500"])
        var wrongIndex = payload(); wrongIndex["index"] = "SPY"
        #expect(throws: AIBenchmarkError.invalidIndex) {
            try value.parseResponse(bytes(envelope([search(sources: sources), message(wrongIndex)])))
        }
        #expect(throws: AIBenchmarkError.invalidWindow) {
            try value.parseResponse(bytes(envelope([search(sources: sources), message(payload(end: "2026-01-28"))])))
        }
        #expect(throws: AIBenchmarkError.invalidPrice) {
            try value.parseResponse(bytes(envelope([search(sources: sources), message(payload(last: "0"))])))
        }
    }

    @Test func resourceQueriesWorkThroughCitationAnnotations() throws {
        let url = source + "?date=2026-01-27&utm_source=chatgpt.com&symbol=SP500#history"
        let result = try request().parseResponse(bytes(envelope([
            search(sources: []), message(payload(), annotations: [citation(url)])
        ])))
        #expect(result.reference?.sourceKind == .answerCitations)
        #expect(result.reference?.sources.map(\.url.absoluteString) == [url])
    }

    @Test func resourceQueriesWorkThroughCompletedPageActions() throws {
        let value = try request(), url = source + "?custom=closing&date=2026-01-27#history"
        for type in ["open_page", "find_in_page"] {
            let result = try value.parseResponse(bytes(envelope([
                search(sources: []), pageAction(type, url: url), message(payload())
            ])))
            #expect(result.reference?.sourceKind == .searchSources)
            #expect(result.reference?.sources.map(\.url.absoluteString) == [url])
        }
    }

    @Test func differentPageAnchorsRemainDifferentDisplayLinks() throws {
        let urls = [source + "#history", source + "#summary", source,
                    source + "#:~:text=Index%20closing%20value", source + "#/history?date=2026-01-27"]
        let result = try request().parseResponse(bytes(envelope([search(sources: metadata(urls)), message(payload())])))
        #expect(result.reference?.sources.map(\.url.absoluteString) == urls)
    }

    @Test func distinctDatedEndpointSourcesRemainDistinct() throws {
        let urls = [source + "?date=2025-01-27&symbol=SP500", source + "?date=2026-01-27&symbol=SP500"]
        let result = try request().parseResponse(bytes(envelope([search(sources: metadata(urls)), message(payload())])))
        #expect(result.reference?.sources.map(\.url.absoluteString) == urls)
        #expect(result.reference?.changePercent == (try Money("10")))
    }

    @Test func obviousCredentialsInQueriesOrFragmentsAreNeverDisplayed() throws {
        let value = try request()
        for suffix in ["?api_key=secret", "?API-KEY=secret", "?utm_source=web&access_token=secret", "#access_token=secret",
                       "?client_secret=secret", "?password=secret", "?authorization=Bearer%20secret", "?session_id=secret",
                       "?X-Amz-Signature=secret", "?q=history%26api_key%3Dsecret", "?%61pi_key=secret",
                       "?%2561pi_key=secret", "?%25252561pi_key=secret", "#:~:text=Index%26token%3Dsecret"] {
            let url = source + suffix
            #expect(throws: AIBenchmarkError.missingSourceMetadata) {
                try value.parseResponse(bytes(envelope([search(sources: metadata([url])), message(payload())])))
            }
            let filtered = try value.parseResponse(bytes(envelope([
                search(sources: metadata([source, url])), message(payload())
            ])))
            #expect(filtered.reference?.sources.map(\.url.absoluteString) == [source])
        }
    }

    @Test func encodedControlsAndMalformedEscapesNeverBecomeSources() throws {
        let value = try request()
        for suffix in ["?q=%0A", "?q=%00", "#history%0D", "/path%250A", "/path%252525250A", "?q=%E2%80%A8",
                       "?q=%E2%80%A9", "?q=%", "?q=%0", "?q=%GG"] {
            #expect(throws: AIBenchmarkError.missingSourceMetadata) {
                try value.parseResponse(bytes(envelope([search(sources: metadata([source + suffix])), message(payload())])))
            }
        }
    }

    @Test func normalFragmentRoutesAndEncodedTextAreRetained() throws {
        let value = try request()
        for fragment in ["/history?date=2026-01-27", "!history", ":~:text=Index%27s%20gain%2010%25",
                         "history:~:text=S%26P%20500", ":~:text=Index%2520value", ":~:text=Index&text=value"] {
            let url = source + "#" + fragment
            let result = try value.parseResponse(bytes(envelope([
                search(sources: []), message(payload(), annotations: [citation(url)])
            ])))
            #expect(result.reference?.sources.map(\.url.absoluteString) == [url])
        }
    }

    @Test func sourceURLBudgetFiltersOversizedLinksWithoutTruncation() throws {
        let value = try request(), prefix = source + "#"
        let atLimit = prefix + String(repeating: "a", count: 2048 - prefix.utf8.count)
        let accepted = try value.parseResponse(bytes(envelope([search(sources: metadata([atLimit])), message(payload())])))
        #expect(accepted.reference?.sources.first?.url.absoluteString == atLimit)
        #expect(throws: AIBenchmarkError.missingSourceMetadata) {
            try value.parseResponse(bytes(envelope([search(sources: metadata([atLimit + "a"])), message(payload())])))
        }
        let filtered = try value.parseResponse(bytes(envelope([
            search(sources: metadata([atLimit + "a", source])), message(payload())
        ])))
        #expect(filtered.reference?.sources.map(\.url.absoluteString) == [source])
    }

    @Test func completeSourceListSupports128EntriesAndBoundsRawMetadata() throws {
        let value = try request(), urls = (0..<128).map { source + "#source-\($0)" }
        let searches = [search(sources: metadata(Array(urls.prefix(64))), id: "first"),
                        search(sources: metadata(Array(urls.suffix(64))), id: "second")]
        let result = try value.parseResponse(bytes(envelope(searches + [message(payload())])))
        try result.validate(for: value)
        #expect(result.reference?.sources.map(\.url.absoluteString) == urls)
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope(searches + [message(payload(), annotations: [citation(source)])])))
        }
    }

    @Test func malformedSourceMetadataCannotBeReplacedWithModelText() throws {
        let value = try request()
        for malformed in [["type": "url", "url": 42], ["type": "url"], ["type": "other", "url": source]] as [[String: Any]] {
            #expect(throws: AIBenchmarkError.invalidEvidence) {
                try value.parseResponse(bytes(envelope([search(sources: [malformed]), message(payload())])))
            }
        }
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([
                search(), message(payload(), annotations: [["type": "url_citation", "url": 42]])
            ])))
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
