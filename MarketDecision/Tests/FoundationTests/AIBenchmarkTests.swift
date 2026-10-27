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
        #expect(throws: AIBenchmarkError.missingSourceMetadata) {
            try value.parseResponse(bytes(envelope([search(sources: []), message(payload())])))
        }
        let citation: [String: Any] = ["type": "url_citation", "url": source, "title": "Synthetic source",
                                       "start_index": 0, "end_index": 20]
        let cited = try value.parseResponse(bytes(envelope([search(sources: []), message(payload(), annotations: [citation])])))
        #expect(cited.reference?.sources[0].url.absoluteString == source)
        var falseReference = payload()
        falseReference["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": "https://www.spglobal.com/invented"]
        #expect(throws: AIBenchmarkError.unmatchedSource) { try value.parseResponse(response(falseReference)) }
    }

    @Test func completedOpenPageURLSuppliesSourceWithoutSourcesOrAnnotations() throws {
        let value = try request()
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), pageAction("open_page", url: source), message(payload())
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == source)
        #expect(reference.endSourceURL.absoluteString == source)
        #expect(reference.sources.map(\.url.absoluteString) == [source])
    }

    @Test func completedFindInPageURLSuppliesSourceWithoutSourcesOrAnnotations() throws {
        let value = try request()
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), pageAction("find_in_page", url: source), message(payload())
        ])))
        try result.validate(for: value)
        #expect(result.reference?.changePercent == (try Money("10")))
        #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
    }

    @Test func completedPageActionURLsUseSharedTrackingNormalization() throws {
        let value = try request()
        var claim = payload()
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": source + "?utm_content=close"]
        for type in ["open_page", "find_in_page"] {
            let result = try value.parseResponse(bytes(envelope([
                search(sources: []), pageAction(type, url: source + "?utm_source=chatgpt.com"), message(claim)
            ])))
            try result.validate(for: value)
            #expect(result.reference?.changePercent == (try Money("10")))
            #expect(result.reference?.startSourceURL.absoluteString == source)
            #expect(result.reference?.endSourceURL.absoluteString == source)
            #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
        }
    }

    @Test func optionalOpenPageURLDoesNotInvalidateOtherValidSources() throws {
        let value = try request()
        let actions = [pageAction("open_page", url: nil), pageAction("open_page", url: NSNull())]
        for action in actions {
            let result = try value.parseResponse(bytes(envelope([search(), action, message(payload())])))
            try result.validate(for: value)
            #expect(result.reference?.changePercent == (try Money("10")))
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

    @Test func differentPageActionPathCannotAuthorizeClaimedSource() throws {
        let value = try request()
        for type in ["open_page", "find_in_page"] {
            #expect(throws: AIBenchmarkError.unmatchedSource) {
                try value.parseResponse(bytes(envelope([
                    search(sources: []), pageAction(type, url: "https://fred.stlouisfed.org/series/OTHER"), message(payload())
                ])))
            }
        }
    }

    @Test func unsafePageActionURLCannotAuthorizeCloseOrPolluteValidReference() throws {
        let value = try request()
        for type in ["open_page", "find_in_page"] {
            for query in ["api_key=secret", "utm_source=chatgpt.com&access_token=secret", "authorization=secret"] {
                let unsafe = source + "?" + query
                var claim = payload()
                claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": unsafe]
                #expect(throws: AIBenchmarkError.unsupportedSourceQuery) {
                    try value.parseResponse(bytes(envelope([
                        search(sources: []), pageAction(type, url: unsafe), message(claim)
                    ])))
                }
                let result = try value.parseResponse(bytes(envelope([
                    search(), pageAction(type, url: unsafe), message(payload())
                ])))
                try result.validate(for: value)
                #expect(result.reference?.sources.map(\.url.absoluteString) == [source])
            }
        }
    }

    @Test func pageActionURLSharesSourceBudgetAndRejectsMalformedMetadata() throws {
        let value = try request()
        let sixtyFour = Array(repeating: ["type": "url", "url": source] as [String: Any], count: 64)
        let atLimit = try value.parseResponse(bytes(envelope([
            search(sources: sixtyFour, id: "ws_first"),
            search(sources: Array(sixtyFour.dropLast()), id: "ws_second"),
            pageAction("open_page", url: source), message(payload())
        ])))
        #expect(atLimit.reference?.changePercent == (try Money("10")))
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([
                search(sources: sixtyFour, id: "ws_first"), search(sources: sixtyFour, id: "ws_second"),
                pageAction("open_page", url: source), message(payload())
            ])))
        }
        #expect(throws: AIBenchmarkError.invalidEvidence) {
            try value.parseResponse(bytes(envelope([
                search(), pageAction("open_page", url: 123), message(payload())
            ])))
        }
    }

    @Test func unsafeCitationsCannotPassEvenWhenSearchMetadataContainsThem() throws {
        let value = try request()
        let cases: [(String, AIBenchmarkError)] = [
            ("http://fred.stlouisfed.org/series/SP500", .unsupportedSourceURL),
            ("https://user:password@fred.stlouisfed.org/series/SP500", .unsupportedSourceURL),
            ("https://fred.stlouisfed.org:443/series/SP500", .unsupportedSourceURL),
            ("https://127.0.0.1/index", .unsupportedSourceURL), ("https://[::1]/index", .unsupportedSourceURL),
            ("https://localhost/index", .unsupportedSourceURL), ("https://service.local/index", .unsupportedSourceURL),
            (source + "?api_key=secret", .unsupportedSourceQuery),
            (source + "#access_token=secret", .unsupportedSourceFragment),
            ("https://fred.stlouisfed.org/a b", .unsupportedSourceURL)
        ]
        for (unsafe, error) in cases {
            var claim = payload(); claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": unsafe]
            let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": unsafe]]
            #expect(throws: error) {
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

    @Test func trackingCannotHideSensitiveOrUnknownQueryParameters() throws {
        let value = try request()
        for query in ["api_key=secret", "api%5Fkey=secret", "access_token=secret", "signature=secret",
                      "source=other",
                      "utm_custom=unrecognized", "UTM_SOURCE=chatgpt.com"] {
            for combined in ["utm_source=chatgpt.com&" + query, query + "&utm_source=chatgpt.com"] {
                let invalidURL = source + "?" + combined
                var claim = payload()
                claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": invalidURL]
                let sources: [[String: Any]] = [["type": "url", "url": source], ["type": "url", "url": invalidURL]]
                #expect(throws: AIBenchmarkError.unsupportedSourceQuery) {
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
            #expect(throws: AIBenchmarkError.unmatchedSource) {
                try value.parseResponse(response(claim))
            }
            let sources: [[String: Any]] = [["type": "url", "url": otherURL]]
            #expect(throws: AIBenchmarkError.unmatchedSource) {
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
            #expect(throws: AIBenchmarkError.unsafeSourceQueryValue) {
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
        #expect(throws: AIBenchmarkError.sourceURLLimit) {
            try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
        }
    }

    @Test func resourceQueryValuesArePreservedInBoundReference() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": resourceURL]]), message(claim)
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == resourceURL)
        #expect(reference.endSourceURL.absoluteString == resourceURL)
        #expect(reference.sources.map(\.url.absoluteString) == [resourceURL])
    }

    @Test func trackingNormalizationPreservesResourceQueryIdentity() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500"
        let metadataURL = source + "?utm_source=chatgpt.com&date=2026-01-27&utm_medium=web&symbol=SP500"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600",
                        "sourceURL": source + "?date=2026-01-27&utm_campaign=closing-values&symbol=SP500&utm_content=end"]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": metadataURL]]), message(claim)
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == resourceURL)
        #expect(reference.endSourceURL.absoluteString == resourceURL)
        #expect(reference.sources.map(\.url.absoluteString) == [resourceURL])
    }

    @Test func changedResourceSelectorsCannotMatchOriginalSource() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500"
        for differentQuery in ["date=2026-01-26&symbol=SP500", "date=2026-01-27&symbol=SPY"] {
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": source + "?" + differentQuery]
            #expect(throws: AIBenchmarkError.unmatchedSource) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func resourceQueryOrderAndPresenceRemainPartOfSourceIdentity() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500"
        for differentURL in [source + "?symbol=SP500&date=2026-01-27", source + "?date=2026-01-27",
                             source + "?symbol=SP500", source] {
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": differentURL]
            #expect(throws: AIBenchmarkError.unmatchedSource) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func resourceQueriesWorkThroughCitationAnnotations() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500#history"
        let citation: [String: Any] = ["type": "url_citation",
            "url": source + "?date=2026-01-27&utm_source=chatgpt.com&symbol=SP500#history",
            "title": "Synthetic closing index reference", "start_index": 0, "end_index": 20]
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: []), message(claim, annotations: [citation])
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == resourceURL)
        #expect(reference.endSourceURL.absoluteString == resourceURL)
        #expect(reference.sources.map(\.url.absoluteString) == [resourceURL])
    }

    @Test func resourceQueriesWorkThroughCompletedPageActions() throws {
        let value = try request()
        let resourceURL = source + "?date=2026-01-27&symbol=SP500#history"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
        for type in ["open_page", "find_in_page"] {
            let actionURL = source + "?utm_source=chatgpt.com&date=2026-01-27&symbol=SP500#history"
            let result = try value.parseResponse(bytes(envelope([
                search(sources: []), pageAction(type, url: actionURL), message(claim)
            ])))
            try result.validate(for: value)
            let reference = try #require(result.reference)
            #expect(reference.changePercent == (try Money("10")))
            #expect(reference.startSourceURL.absoluteString == resourceURL)
            #expect(reference.endSourceURL.absoluteString == resourceURL)
            #expect(reference.sources.map(\.url.absoluteString) == [resourceURL])
        }
    }

    @Test func ordinaryPageAnchorsRemainPartOfBoundSource() throws {
        let value = try request()
        let anchoredURL = source + "#history"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": anchoredURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": anchoredURL]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": source + "?utm_source=chatgpt.com#history"]]), message(claim)
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.startSourceURL.absoluteString == anchoredURL)
        #expect(reference.endSourceURL.absoluteString == anchoredURL)
        #expect(reference.sources.map(\.url.absoluteString) == [anchoredURL])
    }

    @Test func textFragmentSourcesAreRetainedWithoutDroppingEvidence() throws {
        let value = try request()
        let fragmentURL = source + "#:~:text=Index%20closing%20value"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": fragmentURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": fragmentURL]
        let result = try value.parseResponse(bytes(envelope([
            search(sources: [["type": "url", "url": fragmentURL]]), message(claim)
        ])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == fragmentURL)
        #expect(reference.endSourceURL.absoluteString == fragmentURL)
        #expect(reference.sources.map(\.url.absoluteString) == [fragmentURL])
    }

    @Test func differentPageAnchorsCannotAuthorizeClaimedSource() throws {
        let value = try request()
        let anchoredURL = source + "?date=2026-01-27#history"
        for differentURL in [source + "?date=2026-01-27#summary", source + "?date=2026-01-27",
                             source + "?date=2026-01-27#:~:text=Index%20closing%20value"] {
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": anchoredURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": differentURL]
            #expect(throws: AIBenchmarkError.unmatchedSource) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": anchoredURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func distinctDatedEndpointSourcesRemainDistinct() throws {
        let value = try request()
        let firstURL = source + "?date=2025-01-27&symbol=SP500"
        let lastURL = source + "?date=2026-01-27&symbol=SP500"
        var claim = payload()
        claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": firstURL]
        claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": lastURL]
        let sources: [[String: Any]] = [["type": "url", "url": firstURL + "&utm_source=chatgpt.com"],
                                       ["type": "url", "url": lastURL + "&utm_campaign=benchmark"]]
        let result = try value.parseResponse(bytes(envelope([search(sources: sources), message(claim)])))
        try result.validate(for: value)
        let reference = try #require(result.reference)
        #expect(reference.changePercent == (try Money("10")))
        #expect(reference.startSourceURL.absoluteString == firstURL)
        #expect(reference.endSourceURL.absoluteString == lastURL)
        #expect(reference.sources.count == 2)
        #expect(Set(reference.sources.map(\.url.absoluteString)) == Set([firstURL, lastURL]))
    }

    @Test func typedResourceQuerySelectorsRetainOriginalValues() throws {
        let value = try request()
        let queries = [
            "id=SP500&series_id=SP500&series=SP500&symbol=%5EGSPC&ticker=SP500&index=SP500&s=SP500",
            "date=2026-01-27&start_date=2025-01-27&end_date=20260127&from=20250127&to=2026-01-27",
            "start=2025-01-27&end=20260127&cosd=2025-01-27&coed=2026-01-27&d1=20250127&d2=20260127",
            "period1=1738011600&period2=1769547600000&page=1&offset=0&limit=100000",
            "interval=1d&frequency=daily&i=d&filter=history&events=history",
            "date=2024-02-29", "date=20240229", "sym%62ol=%5EGSPC", "id=" + String(repeating: "x", count: 80)
        ]
        for query in queries {
            let resourceURL = source + "?" + query
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": resourceURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
            let result = try value.parseResponse(bytes(envelope([
                search(sources: [["type": "url", "url": resourceURL]]), message(claim)
            ])))
            try result.validate(for: value)
            let reference = try #require(result.reference)
            #expect(reference.changePercent == (try Money("10")))
            #expect(reference.startSourceURL.absoluteString == resourceURL)
            #expect(reference.endSourceURL.absoluteString == resourceURL)
            #expect(reference.sources.map(\.url.absoluteString) == [resourceURL])
        }
    }

    @Test func resourceQueryDatesRejectImpossibleOrOutOfRangeDays() throws {
        let value = try request()
        for day in ["2026-02-29", "20260229", "1900-02-29", "2026-04-31", "2026-00-01", "2026-13-01",
                    "2026-01-00", "1899-12-31", "2201-01-01", "2026-1-27", "2026/01/27", "2026-01-27T21:00:00Z"] {
            let resourceURL = source + "?date=" + day
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
            #expect(throws: AIBenchmarkError.unsafeSourceQueryValue) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func resourceQueryDuplicateAndEncodedDuplicateKeysAreRejected() throws {
        let value = try request()
        for query in ["symbol=SP500&symbol=SP500", "date=2026-01-27&date=2026-01-26",
                      "symbol=SP500&sym%62ol=SP500", "sym%62ol=SP500&symbol=SP500",
                      "date=2026-01-27&%64ate=2026-01-27", "symbol=SP500&utm_source=web&symbol=SP500"] {
            let resourceURL = source + "?" + query
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
            #expect(throws: AIBenchmarkError.unsafeSourceQueryValue) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func resourceQueryValuesRejectNestedDoubleEncodedAndOutOfTypeValues() throws {
        let value = try request()
        let queries = [
            "symbol", "symbol=", "symbol=SP500%26api_key%3Dsecret", "symbol=SP500%3Btoken%3Dsecret",
            "symbol=%255EGSPC", "symbol=SP500%250A", "symbol=SP500%0A", "symbol=SP500%00",
            "symbol=SP500%20OTHER", "id=" + String(repeating: "x", count: 81),
            "symbol=" + String(repeating: "x", count: 257),
            "period1=-1", "period2=1.5", "period1=12345678901234", "page=one", "offset=-1", "limit=1000000",
            "interval=1h", "frequency=unknown", "filter=private", "events=dividends"
        ]
        for query in queries {
            let resourceURL = source + "?" + query
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
            #expect(throws: AIBenchmarkError.unsafeSourceQueryValue) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func unsupportedResourceKeysCannotBeSmuggledByEncoding() throws {
        let value = try request()
        for query in ["%2564ate=2026-01-27", "%2561pi_key=secret", "DATE=2026-01-27", "redirect=history",
                      "url=https%3A%2F%2Ffred.stlouisfed.org", "symbol=SP500&", "=SP500"] {
            let resourceURL = source + "?" + query
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": resourceURL]
            #expect(throws: AIBenchmarkError.unsupportedSourceQuery) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": resourceURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func textFragmentPercentAndApostropheAreRetained() throws {
        let value = try request()
        for fragment in [":~:text=Index%27s%20closing%20value", ":~:text=Index%20gain%2010%25",
                         "history:~:text=S%26P%20500%27s%20gain%2010%25"] {
            let fragmentURL = source + "#" + fragment
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": fragmentURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": fragmentURL]
            let result = try value.parseResponse(bytes(envelope([
                search(sources: [["type": "url", "url": fragmentURL]]), message(claim)
            ])))
            try result.validate(for: value)
            let reference = try #require(result.reference)
            #expect(reference.changePercent == (try Money("10")))
            #expect(reference.startSourceURL.absoluteString == fragmentURL)
            #expect(reference.endSourceURL.absoluteString == fragmentURL)
            #expect(reference.sources.map(\.url.absoluteString) == [fragmentURL])
        }
    }

    @Test func fragmentsRejectRoutesDirectivesControlsAndDoubleEncoding() throws {
        let value = try request()
        for fragment in ["access_token=secret", "/history?date=2026-01-27", "!history", "history%0A",
                         "history%00", ":~:text=Index&text=value", ":~:text=Index:~:text=other",
                         ":~:text=Index%26token%3Dsecret", ":~:text=https%3A%2F%2Ffred.stlouisfed.org",
                         ":~:text=Index%0Avalue", ":~:text=Index%00value", ":~:text=Index%2520value",
                         ":~:text=Index%2541", String(repeating: "a", count: 129),
                         ":~:text=" + String(repeating: "a", count: 513)] {
            let fragmentURL = source + "#" + fragment
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": fragmentURL]
            #expect(throws: AIBenchmarkError.unsupportedSourceFragment) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": fragmentURL]]), message(claim)
                ])))
            }
        }
    }

    @Test func boundedTextAndAnchorFragmentsKeepTheirCompleteContents() throws {
        let value = try request()
        for fragment in [String(repeating: "a", count: 128), ":~:text=" + String(repeating: "a", count: 512)] {
            let fragmentURL = source + "#" + fragment
            var claim = payload()
            claim["start"] = ["day": "2025-01-27", "close": "6000", "sourceURL": fragmentURL]
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": fragmentURL]
            let result = try value.parseResponse(bytes(envelope([
                search(sources: [["type": "url", "url": fragmentURL]]), message(claim)
            ])))
            try result.validate(for: value)
            #expect(result.reference?.startSourceURL.absoluteString == fragmentURL)
            #expect(result.reference?.endSourceURL.absoluteString == fragmentURL)
            #expect(result.reference?.sources.map(\.url.absoluteString) == [fragmentURL])
        }
    }

    @Test func sourceURLAndFragmentBudgetsFailClosed() throws {
        let value = try request()
        for excessiveURL in [source + "/" + String(repeating: "a", count: 2048),
                             source + "#" + String(repeating: "a", count: 769)] {
            var claim = payload()
            claim["end"] = ["day": "2026-01-27", "close": "6600", "sourceURL": excessiveURL]
            #expect(throws: AIBenchmarkError.sourceURLLimit) {
                try value.parseResponse(bytes(envelope([
                    search(sources: [["type": "url", "url": source], ["type": "url", "url": excessiveURL]]), message(claim)
                ])))
            }
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
