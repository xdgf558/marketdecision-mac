import Foundation
import CoreDomain

/// Pure replay of the bounded candidate envelope, shared by ingest, reopen and archive validation.
/// Timestamp units are explicitly frozen because endpoint examples have used differing units;
/// neither digit count nor local receipt time is substituted for a missing source clock.
public enum OptionChainDecoder {
    public static func replay(id: UUID, createdAt: Date, requestedAt: Date, symbol: String,
                              environment: OptionChainEnvironment, timestampUnit: OptionChainTimestampUnit, synthetic: Bool,
                              rights: OptionChainRights, requestedExpirations: [MarketDate], pages: [OptionChainRawPage]) throws -> OptionChainSnapshot {
        try EquityRecord.validateSymbol(symbol)
        guard finite(createdAt), finite(requestedAt), requestedAt <= createdAt,
              !requestedExpirations.isEmpty, requestedExpirations.count <= 12,
              requestedExpirations == requestedExpirations.sorted(), Set(requestedExpirations).count == requestedExpirations.count,
              (1...14).contains(pages.count), pages.reduce(0, { $0 + $1.bytes.count }) <= 32 * 1_024 * 1_024 else {
            throw ContractError.invalidCoverage
        }
        for expiry in requestedExpirations { _ = try expiry.start(in: TimeZone(secondsFromGMT: 0)!) }
        let capability = OptionChainCapture.capabilities(environment: environment)
        let entitlement = rights.entitlement(environment: environment)
        var underlying: OptionChainQuote?, expirations: [MarketDate] = [], completed: [MarketDate] = []
        var contracts: [OptionChainContract] = [], failures: [ProviderFailure] = []
        var priorReceived = requestedAt
        var seenPages = Set<String>()
        for (index, page) in pages.enumerated() {
            let request = page.request
            let expectedCapability: ProviderCapability = index == 0 ? .quote : (index == 1 ? .optionExpirations : .optionChain)
            guard request.id == id, request.requestedAt == requestedAt, request.resourceID == symbol,
                  request.capability == expectedCapability, request.usage == .replay,
                  request.mode == .latest, request.range == nil, request.pageToken == nil,
                  finite(page.receivedAt), priorReceived <= page.receivedAt, page.receivedAt <= createdAt,
                  !page.bytes.isEmpty, page.bytes.count <= 4 * 1_024 * 1_024,
                  page.contentHash == digest(page.bytes), seenPages.insert(page.reference).inserted,
                  failures.isEmpty else { throw ContractError.mismatchedSource }
            let session = try ProviderSession(request: request, capabilities: capability, entitlement: entitlement)
            guard entitlement.permits(provider: request.providerID, feed: request.feedID, usage: request.usage, at: page.receivedAt) else {
                throw ProviderFailure.notEntitled
            }
            priorReceived = page.receivedAt
            if expectedCapability == .optionChain {
                guard index - 2 < requestedExpirations.count, page.expiration == requestedExpirations[index - 2],
                      let expiry = page.expiration, expirations.contains(expiry) else { throw ContractError.invalidCoverage }
            } else if page.expiration != nil { throw ContractError.invalidCoverage }
            guard (100...599).contains(page.statusCode) else { throw ContractError.invalidCoverage }
            if page.statusCode != 200 {
                let failure: ProviderFailure = page.statusCode == 404 ? .symbolUnavailable : ProviderFailure.fromHTTP(page.statusCode)
                failures.append(failure)
                _ = try session.accept(ProviderResult<OptionChainQuote>(request: request, receivedAt: page.receivedAt,
                    items: [], coverage: .init(expectedCount: nil), errors: [failure]))
                continue
            }
            let body = try ExactMarketJSON.parse(page.bytes)
            switch expectedCapability {
            case .quote:
                guard let quotes = body.object?["quotes"] else { throw ProviderFailure.malformedResponse }
                let records: [OptionChainQuote]
                if quotes.isNull { records = [] }
                else {
                    guard let field = quotes.object?["quote"] else { throw ProviderFailure.malformedResponse }
                    let values = try objects(field)
                    guard values.count <= 1 else { throw ProviderFailure.malformedResponse }
                    records = try values.map {
                        guard let kind = $0["type"]?.string, ["stock", "etf"].contains(kind) else {
                            throw ProviderFailure.malformedResponse
                        }
                        return try quote($0, symbol: symbol, page: page, environment: environment,
                            unit: timestampUnit, synthetic: synthetic, rights: rights)
                    }
                }
                _ = try session.accept(ProviderResult(request: request, receivedAt: page.receivedAt, items: records,
                    coverage: .init(expectedCount: records.count), emptyReason: records.isEmpty ? .noResults : nil))
                underlying = records.first
            case .optionExpirations:
                guard let root = body.object?["expirations"] else { throw ProviderFailure.malformedResponse }
                if root.isNull { expirations = [] }
                else {
                    guard let field = root.object?["date"] else { throw ProviderFailure.malformedResponse }
                    let strings: [String]
                    if field.isNull { strings = [] }
                    else if let value = field.string { strings = [value] }
                    else if let array = field.array {
                        strings = try array.map { guard let value = $0.string else { throw ProviderFailure.malformedResponse }; return value }
                    } else { throw ProviderFailure.malformedResponse }
                    expirations = try strings.map(MarketDate.init(iso8601:)).sorted()
                    guard expirations.count <= 500, Set(expirations).count == expirations.count else { throw ContractError.duplicateRecord }
                }
                let records = expirations.map { ExpirationRecord(recordID: $0.iso8601,
                    provenance: provenance(page: page, time: nil, rights: rights)) }
                _ = try session.accept(ProviderResult(request: request, receivedAt: page.receivedAt, items: records,
                    coverage: .init(expectedCount: records.count), emptyReason: records.isEmpty ? .noListedContracts : nil))
            case .optionChain:
                guard let expiry = page.expiration, let root = body.object?["options"] else { throw ProviderFailure.malformedResponse }
                let values: [[String: ExactMarketJSON]]
                if root.isNull { values = [] }
                else { guard let field = root.object?["option"] else { throw ProviderFailure.malformedResponse }; values = try objects(field) }
                guard values.count <= 2000 else { throw ContractError.invalidCoverage }
                let records = try values.map { object -> OptionChainContract in
                    guard let contractID = object["symbol"]?.string, contractID.utf8.count <= 64,
                          contractID.range(of: #"^[A-Z0-9.]+\z"#, options: .regularExpression) != nil,
                          object["type"]?.string == "option", object["underlying"]?.string == symbol,
                          object["expiration_date"]?.string == expiry.iso8601,
                          let rightText = object["option_type"]?.string, let right = OptionChainRight(rawValue: rightText),
                          let multiplier = try object["contract_size"]?.integer(), (1...10000).contains(multiplier),
                          let strike = try object["strike"]?.money(), strike.amount > 0 else { throw ProviderFailure.malformedResponse }
                    let value = try quote(object, symbol: contractID, page: page, environment: environment,
                        unit: timestampUnit, synthetic: synthetic, rights: rights)
                    return .init(underlyingSymbol: symbol, expiration: expiry, right: right, strike: strike,
                        multiplier: multiplier, quote: value, observedVolume: try integer(object["volume"]),
                        observedOpenInterest: try integer(object["open_interest"]))
                }.sorted { $0.recordID < $1.recordID }
                _ = try session.accept(ProviderResult(request: request, receivedAt: page.receivedAt, items: records,
                    coverage: .init(expectedCount: records.count), emptyReason: records.isEmpty ? .noListedContracts : nil))
                contracts += records; completed.append(expiry)
            default: throw ContractError.invalidRequest
            }
        }
        guard Set(contracts.map(\.recordID)).count == contracts.count else { throw ContractError.duplicateRecord }
        if let underlying, !contracts.isEmpty, let last = pages.last {
            let cycle = Cycle(recordID: symbol, provenance: provenance(page: last,
                time: nil, rights: rights), underlyingQuote: underlying.quote, contractProvenances: contracts.map(\.provenance))
            try cycle.validateRequestCycle()
        }
        let status: OptionChainCaptureStatus
        if !failures.isEmpty { status = contracts.isEmpty ? .error : .partial }
        else if underlying != nil, pages.count == 2, expirations.isEmpty { status = .empty }
        else if underlying == nil || completed != requestedExpirations { status = .partial }
        else { status = contracts.isEmpty ? .empty : .complete }
        return .init(status: status, listedExpirations: expirations, requestedExpirations: requestedExpirations,
                     completedExpirations: completed, underlying: underlying, contracts: contracts, failures: failures)
    }
    private static func objects(_ field: ExactMarketJSON) throws -> [[String: ExactMarketJSON]] {
        if field.isNull { return [] }
        if let object = field.object { return [object] }
        guard let array = field.array else { throw ProviderFailure.malformedResponse }
        return try array.map { guard let object = $0.object else { throw ProviderFailure.malformedResponse }; return object }
    }
    private static func integer(_ field: ExactMarketJSON?) throws -> Int? {
        guard let field, !field.isNull else { return nil }; return try field.integer()
    }
    private static func quote(_ value: [String: ExactMarketJSON], symbol: String, page: OptionChainRawPage,
                              environment: OptionChainEnvironment, unit: OptionChainTimestampUnit,
                              synthetic: Bool, rights: OptionChainRights) throws -> OptionChainQuote {
        guard value["symbol"]?.string == symbol, let bid = try value["bid"]?.money(), let ask = try value["ask"]?.money(),
              bid.amount >= 0, ask.amount >= 0, let bidSize = try value["bidsize"]?.integer(),
              let askSize = try value["asksize"]?.integer() else { throw ProviderFailure.malformedResponse }
        let bidAt = try timestamp(value["bid_date"], unit: unit), askAt = try timestamp(value["ask_date"], unit: unit)
        guard bidAt.map({ $0 <= page.receivedAt }) ?? true, askAt.map({ $0 <= page.receivedAt }) ?? true else {
            throw ContractError.invalidTime
        }
        let time = bidAt.flatMap { bid in askAt.map { min(bid, $0) } }
        var quality: Set<QualityFlag> = synthetic ? [.synthetic] : []
        if bid.amount > ask.amount || bid.amount == 0 || ask.amount == 0 || bidSize == 0 || askSize == 0 { quality.insert(.invalid) }
        if time == nil { quality.insert(.missing) }
        if let time, page.receivedAt.timeIntervalSince(time) > FreshnessPolicy.foundationV1.realtimeMaxAge { quality.insert(.stale) }
        return .init(symbol: symbol, bid: bid, ask: ask, bidSize: bidSize, askSize: askSize, bidAt: bidAt, askAt: askAt,
            provenance: provenance(page: page, time: time, rights: rights), timeliness: environment.timeliness, quality: quality)
    }
    private static func timestamp(_ field: ExactMarketJSON?, unit: OptionChainTimestampUnit) throws -> Date? {
        guard let value = try integer(field), value != 0 else { return nil }
        let seconds = Double(value) / (unit == .unixMilliseconds ? 1000 : 1)
        // Reject nonsensical unit/configuration mismatches rather than silently guessing.
        guard seconds >= 946684800, seconds <= 7258118400 else { throw ContractError.invalidTime }
        return Date(timeIntervalSince1970: seconds)
    }
    private static func provenance(page: OptionChainRawPage, time: Date?, rights: OptionChainRights) -> Provenance {
        .init(providerID: page.request.providerID, feedID: page.request.feedID, sourceEventAt: time,
            receivedAt: page.receivedAt, availableAt: nil, evidenceRef: rights.evidenceRef, origin: .provider,
            endpointDescriptor: page.request.capability.endpointDescriptor.rawValue, requestedAt: page.request.requestedAt,
            requestID: page.request.id, versionID: page.contentHash, versionKind: .localContent, availability: .unknown,
            rawObjectRef: page.reference, rawHash: page.contentHash, normalizationVersion: OptionChainCapture.configurationVersion,
            licenseRef: rights.licenseRef, attribution: "Tradier candidate; account/feed qualification not inferred")
    }
    private struct ExpirationRecord: ProviderRecord { let recordID: String; let provenance: Provenance }
    private struct Cycle: OptionChainRecord {
        let recordID: String; let provenance: Provenance; let underlyingQuote: Quote; let contractProvenances: [Provenance]
    }
}
