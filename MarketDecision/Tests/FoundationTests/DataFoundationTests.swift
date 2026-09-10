import Foundation
import CryptoKit
import Testing
import CoreDomain
import DataContracts
import DataProviders

private let fixtureNow = Date(timeIntervalSince1970: 1_783_000_000)
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func request(_ capability: ProviderCapability = .quote, id: UUID = UUID(), feed: String = "feed-a", resource: String = "TEST",
                     mode: QueryMode = .latest, range: DataWindow? = nil, configuration: String = "caps.v1", page: String? = nil) -> ProviderRequest {
    ProviderRequest(id: id, providerID: "fixture", feedID: feed, resourceID: resource, capability: capability, mode: mode,
                    range: range, usage: .liveAnalysis, configurationVersion: configuration, entitlementVersion: "rights.v1", requestedAt: fixtureNow, pageToken: page)
}
private func source(_ request: ProviderRequest, version: String = "v1", time: Date? = fixtureNow,
                    availability: AvailabilityEvidence = .unknown, kind: VersionKind = .sourceVersion,
                    endpoint: String = EndpointDescriptor.quote.rawValue, origin: OriginKind = .provider, license: String = "license.v1",
                    observation: MarketDate? = .init(year: 2025, month: 3, day: 31)) -> Provenance {
    let raw = Data("synthetic-\(version)".utf8)
    return Provenance(providerID: request.providerID, feedID: request.feedID, sourceEventAt: time, receivedAt: request.requestedAt,
                      availableAt: utc("2025-01-01T00:00:00Z"), evidenceRef: "fixture.evidence", origin: origin,
                      endpointDescriptor: endpoint, requestedAt: request.requestedAt, requestID: request.id,
                      observationDate: observation, versionID: version, versionKind: kind,
                      availability: availability, rawObjectRef: "raw.\(version)",
                      rawHash: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(), normalizationVersion: "normalize.v1",
                      licenseRef: license, legacySourceTimestamp: utc("2020-01-01T00:00:00Z"))
}
private func fixtureQuote(_ request: ProviderRequest, source provenance: Provenance? = nil, tier: Timeliness = .realtime,
                   flags: Set<QualityFlag> = [], symbol: String? = nil) throws -> Quote {
    Quote(symbol: symbol ?? request.resourceID, bid: try Money("1"), ask: try Money("2"), provenance: provenance ?? source(request),
          timeliness: tier, quality: flags, qualifiedUsages: Set(Usage.allCases))
}
private func rights(feed: String = "feed-a", usages: Set<Usage> = Set(Usage.allCases), through: Date = fixtureNow.addingTimeInterval(60)) -> EntitlementSnapshot {
    EntitlementSnapshot(providerID: "fixture", feedID: feed, version: "rights.v1", evidenceRef: "synthetic-rights", licenseRef: "license.v1",
                        capabilities: Set(ProviderCapability.allCases), usages: usages,
                        validFrom: fixtureNow.addingTimeInterval(-60), validThrough: through)
}
private func capabilities(asOf: Bool = false) -> CapabilitySnapshot {
    CapabilitySnapshot(providerID: "fixture", version: "caps.v1", feeds: ["feed-a", "feed-b"], capabilities: Set(ProviderCapability.allCases),
                       asOfCapabilities: asOf ? [.quote, .macroSeries] : [], vintageResourceIDs: asOf ? ["TEST"] : [])
}
private struct SampleRecord: ProviderRecord {
    let recordID: String
    let provenance: Provenance
    let value: Int
}
private struct SampleChain: OptionChainRecord {
    let recordID = "chain"
    let provenance: Provenance
    let underlyingQuote: Quote
    let contractProvenances: [Provenance]
}

@Suite struct DataProvenanceTests {
    @Test func vintageSelectionNeverFallsBackToLatest() throws {
        let r = request(.macroSeries)
        let v1 = SampleRecord(recordID: "observation", provenance: source(r, version: "v1", availability: .instant(utc("2025-05-01T13:00:00Z"), evidence: "v1.release")), value: 100)
        let v2 = SampleRecord(recordID: "observation", provenance: source(r, version: "v2", availability: .instant(utc("2025-06-01T13:00:00Z"), evidence: "v2.release")), value: 120)
        let cutoff = utc("2025-05-15T13:00:00Z")
        #expect(try AsOfSelector.select([v2, v1], cutoff: cutoff).value == 100)
        #expect(throws: UnavailableReason.pitUnavailable) { try AsOfSelector.select([v2], cutoff: cutoff) }
        #expect(try AsOfSelector.select([v1, v2], cutoff: utc("2025-06-01T13:00:00Z")).value == 120)
        // Received in a later collection cycle is fine; the version evidence controls historical visibility.
        #expect(v1.provenance.receivedAt > cutoff && v1.provenance.isAvailable(asOf: cutoff))
    }
    @Test func dateOnlyReleaseUsesNextLocalDayIncludingDST() throws {
        let evidence = AvailabilityEvidence.dateOnly(MarketDate(year: 2025, month: 3, day: 9), timeZoneID: "America/New_York", evidence: "date-proof")
        #expect(try evidence.upperBound() == utc("2025-03-10T04:00:00Z"))
        let p = source(request(), availability: evidence)
        #expect(!p.isAvailable(asOf: utc("2025-03-10T03:59:59Z")))
        #expect(p.isAvailable(asOf: utc("2025-03-10T04:00:00Z")))
    }
    @Test func unknownZoneInvalidDayAndBlankEvidenceAreRejected() {
        for evidence in [AvailabilityEvidence.dateOnly(.init(year: 2025, month: 5, day: 1), timeZoneID: "Unknown/Zone", evidence: "proof"),
                         .dateOnly(.init(year: 2025, month: 2, day: 30), timeZoneID: "UTC", evidence: "proof"),
                         .instant(fixtureNow, evidence: " "), .interval(earliest: fixtureNow, latest: fixtureNow.addingTimeInterval(-1), evidence: "proof")] {
            #expect(throws: (any Error).self) { try evidence.upperBound() }
        }
    }
    @Test func intervalRequiresItsUpperBoundAndCannotUseLegacyTimestamps() throws {
        let p = source(request(), availability: .interval(earliest: fixtureNow.addingTimeInterval(-10), latest: fixtureNow, evidence: "range-proof"))
        #expect(!p.isAvailable(asOf: fixtureNow.addingTimeInterval(-1)))
        #expect(p.isAvailable(asOf: fixtureNow))
        #expect(!source(request()).isAvailable(asOf: fixtureNow))
        #expect(!source(request(), availability: .instant(fixtureNow, evidence: "proof"), kind: .localContent).isAvailable(asOf: fixtureNow))
    }
    @Test func versionTiesDuplicateIDsAndMixedFeedsAreNotSilentlyResolved() throws {
        let r = request(); let p = source(r, availability: .instant(fixtureNow, evidence: "proof"))
        let a = SampleRecord(recordID: "obs", provenance: p, value: 1)
        let b = SampleRecord(recordID: "obs", provenance: source(r, version: "v2", availability: .instant(fixtureNow, evidence: "proof")), value: 2)
        #expect(throws: ContractError.ambiguousVersion) { try AsOfSelector.select([a, b], cutoff: fixtureNow) }
        #expect(throws: ContractError.duplicateRecord) { try AsOfSelector.select([a, a], cutoff: fixtureNow) }
        let other = SampleRecord(recordID: "obs", provenance: source(request(feed: "feed-b"), version: "v2"), value: 2)
        #expect(throws: ContractError.mismatchedSource) { try AsOfSelector.select([a, other], cutoff: fixtureNow) }
    }
    @Test func endpointTemplatesRejectCredentialURLsAndDecodedInvalidMetadata() throws {
        for endpoint in ["https://service/quote?api_key=synthetic", "quotes?token=synthetic", "user@service", "../secret"] {
            #expect(throws: ContractError.invalidEndpoint) { try source(request(), endpoint: endpoint).validate() }
        }
        let valid = source(request())
        let bytes = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(Provenance.self, from: bytes) == valid)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["providerID"] = " "
        let decoded = try JSONDecoder().decode(Provenance.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: ContractError.invalidIdentity) { try decoded.validate() }
    }
    @Test func malformedSourceTimeCannotPassLiveEvaluation() throws {
        let r = request()
        let bad = source(r, time: Date(timeIntervalSince1970: .infinity))
        #expect(try fixtureQuote(r, source: bad).eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights()).failure == .incompleteProvenance)
        #expect(try fixtureQuote(r).eligibility(for: .liveAnalysis, at: fixtureNow.addingTimeInterval(-1), entitlement: rights()).failure == .invalidTime)
    }
    @Test func rightsAndUsagesCannotBeInferredFromCapabilityOrQuoteClaims() throws {
        let q = try fixtureQuote(request())
        #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow).failure == .notEntitled)
        #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights(feed: "feed-b")).failure == .notEntitled)
        #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights(through: fixtureNow.addingTimeInterval(-1))).failure == .notEntitled)
        #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights()).failure == nil)
        for usage in Usage.allCases where usage != .liveAnalysis {
            #expect(q.eligibility(for: usage, at: fixtureNow, entitlement: rights()).failure == .unqualifiedUsage)
        }
    }
    @Test func displayProjectionNeverUpgradesImportedOrDerivedPrices() throws {
        for origin in [OriginKind.userImport, .derived] {
            let q = try fixtureQuote(request(), source: source(request(), origin: origin), tier: .delayed)
            #expect(q.legacyDataTier == (origin == .derived ? .derived : .userImport))
            #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights()).failure == .unsuitableTier)
        }
        let legacy = Provenance(providerID: "fixture", feedID: "feed-a", sourceEventAt: fixtureNow, receivedAt: fixtureNow, availableAt: fixtureNow, evidenceRef: "proof", origin: .userImport)
        #expect(try fixtureQuote(request(), source: legacy).eligibility(for: .liveAnalysis, at: fixtureNow, entitlement: rights()).failure == .incompleteProvenance)
    }
}
private extension Result where Failure == UnavailableReason {
    var failure: UnavailableReason? { if case let .failure(reason) = self { reason } else { nil } }
}

@Suite struct ProviderEnvelopeTests {
    @Test func capabilityRightsAndHistoricalSupportAreIndependent() throws {
        let r = request()
        #expect(throws: ProviderFailure.notEntitled) { try ProviderAccess.validate(r, capabilities: capabilities(), entitlement: nil) }
        #expect(throws: ProviderFailure.notEntitled) { try ProviderAccess.validate(r, capabilities: capabilities(), entitlement: rights(feed: "feed-b")) }
        let historical = request(mode: .asOf(fixtureNow), range: .sourceEvents(.init(start: fixtureNow.addingTimeInterval(-10), end: fixtureNow)))
        #expect(throws: ProviderFailure.unsupported) { try ProviderAccess.validate(historical, capabilities: capabilities(), entitlement: rights()) }
        try ProviderAccess.validate(historical, capabilities: capabilities(asOf: true), entitlement: rights())
        let wrongResource = request(resource: "UNVERIFIED", mode: .asOf(fixtureNow), range: historical.range)
        #expect(throws: ProviderFailure.unsupported) { try ProviderAccess.validate(wrongResource, capabilities: capabilities(asOf: true), entitlement: rights()) }
    }
    @Test func requestsRejectMissingRangeFutureCutoffAndInvalidTimes() {
        #expect(throws: ContractError.invalidRequest) { try request(mode: .asOf(fixtureNow)).validate() }
        #expect(throws: ContractError.invalidRequest) { try request(mode: .asOf(fixtureNow.addingTimeInterval(1)), range: .sourceEvents(.init(start: fixtureNow, end: fixtureNow))).validate() }
        #expect(throws: ContractError.invalidRange) { try request(range: .sourceEvents(.init(start: fixtureNow, end: fixtureNow.addingTimeInterval(-1)))).validate() }
        #expect(throws: ContractError.invalidRange) { try DateRange(start: Date(timeIntervalSince1970: .nan), end: fixtureNow).validate() }
    }
    @Test func emptyPartialCompleteAndErrorRemainDistinct() throws {
        let r = request(); let q = try fixtureQuote(r)
        #expect(try ProviderResult(request: r, receivedAt: fixtureNow, items: [q], coverage: .init(expectedCount: 1)).status == .complete)
        #expect(try ProviderResult(request: r, receivedAt: fixtureNow, items: [q], coverage: .init(expectedCount: 1, truncated: true)).status == .partial)
        #expect(try ProviderResult<Quote>(request: r, receivedAt: fixtureNow, items: [], coverage: .init(expectedCount: 0), emptyReason: .marketClosed).status == .empty)
        #expect(try ProviderResult<Quote>(request: r, receivedAt: fixtureNow, items: [], coverage: .init(expectedCount: nil), errors: [.notEntitled]).status == .error)
        #expect(throws: ContractError.invalidCoverage) { try ProviderResult<Quote>(request: r, receivedAt: fixtureNow, items: [], coverage: .init(expectedCount: 0)) }
        #expect(ProviderFailure.fromHTTP(403) == .notEntitled)
        #expect(ProviderFailure.fromHTTP(429) == .rateLimited)
    }
    @Test func pagingAndMissingItemsNeverBecomeComplete() throws {
        let r = request(.bars); let item = SampleRecord(recordID: "bar-1", provenance: source(r), value: 1)
        let paged = try ProviderResult(request: r, receivedAt: fixtureNow, items: [item], coverage: .init(expectedCount: nil), nextPageToken: "page-2")
        #expect(paged.status == .partial && paged.nextPageToken == "page-2")
        let missing = try ProviderResult(request: r, receivedAt: fixtureNow, items: [item], coverage: .init(expectedCount: 2, missing: [.init(resourceID: "bar-2", reason: .offline)]))
        #expect(missing.status == .partial && missing.coverage.missing.count == 1)
        #expect(throws: ContractError.invalidCoverage) { try ProviderResult(request: r, receivedAt: fixtureNow, items: [item], coverage: .init(expectedCount: 0)) }
        #expect(throws: ContractError.duplicateRecord) { try ProviderResult(request: r, receivedAt: fixtureNow, items: [item, item], coverage: .init(expectedCount: 2)) }
    }
    @Test func responseCannotSubstituteRequestFeedResourceOrLicense() throws {
        let r = request(); let q = try fixtureQuote(r)
        let result = try ProviderResult(request: r, receivedAt: fixtureNow, items: [q], coverage: .init(expectedCount: 1))
        #expect(throws: ContractError.mismatchedRequest) { try result.validate(matching: request()) }
        #expect(throws: ContractError.mismatchedSource) {
            try ProviderResult(request: r, receivedAt: fixtureNow, items: [fixtureQuote(r, source: source(request(feed: "feed-b")))], coverage: .init(expectedCount: 1))
        }
        let session = try ProviderSession(request: r, capabilities: capabilities(), entitlement: rights())
        let wrongSymbol = try ProviderResult(request: r, receivedAt: fixtureNow, items: [fixtureQuote(r, symbol: "OTHER")], coverage: .init(expectedCount: 1))
        #expect(throws: ContractError.mismatchedSource) { try session.accept(wrongSymbol) }
        let wrongLicense = try ProviderResult(request: r, receivedAt: fixtureNow, items: [fixtureQuote(r, source: source(r, license: "other"))], coverage: .init(expectedCount: 1))
        #expect(throws: ProviderFailure.notEntitled) { try session.accept(wrongLicense) }
        let accepted = try session.accept(result)
        #expect(accepted.capabilities.version == "caps.v1" && accepted.entitlement.version == r.entitlementVersion)
        #expect(accepted.result.sourceManifest == [q.provenance])
    }
    @Test func asOfResponseCannotSmuggleCurrentOrUnversionedValues() throws {
        let cutoff = fixtureNow.addingTimeInterval(-60)
        let r = request(mode: .asOf(cutoff), range: .sourceEvents(.init(start: cutoff.addingTimeInterval(-60), end: cutoff)))
        for p in [source(r), source(r, availability: .instant(fixtureNow, evidence: "new-version")), source(r, availability: .instant(cutoff, evidence: "proof"), kind: .localContent)] {
            #expect(throws: ProviderFailure.pitUnavailable) { try ProviderResult(request: r, receivedAt: fixtureNow, items: [fixtureQuote(r, source: p)], coverage: .init(expectedCount: 1)) }
        }
        let valid = try ProviderResult(request: r, receivedAt: fixtureNow, items: [fixtureQuote(r, source: source(r, time: cutoff, availability: .instant(cutoff, evidence: "old-version")))], coverage: .init(expectedCount: 1))
        #expect(valid.status == .complete)
    }
    @Test func mockScenariosRemainSyntheticAndExplicitlyUnsupported() async throws {
        for scenario in [MockQuoteProvider.Scenario.complete, .partial, .empty, .failure(.rateLimited)] {
            let provider = MockQuoteProvider(scenario: scenario)
            let result = try await provider.quote(request: provider.request(for: "DEMO", at: fixtureNow))
            for q in result.items { #expect(q.eligibility(for: .liveAnalysis, at: fixtureNow).failure == .syntheticData) }
            switch scenario {
            case .complete: #expect(result.status == .complete)
            case .partial: #expect(result.status == .partial)
            case .empty: #expect(result.status == .empty)
            case .failure: #expect(result.status == .error)
            }
        }
        let p = MockQuoteProvider()
        await #expect(throws: ProviderFailure.unsupported) { try await p.optionChain(request: p.request(for: "DEMO", at: fixtureNow)) }
        await #expect(throws: ProviderFailure.malformedResponse) { try await MockQuoteProvider(scenario: .partial).quote(for: "DEMO") }
    }
}

@Suite struct DataInheritanceTests {
    private func input(_ id: String, role: DependencyRole = .required, origin: OriginKind = .provider,
                       price: Bool = true, tier: Timeliness = .realtime, quality: Set<QualityFlag> = [],
                       reasons: Set<UnavailableReason> = []) -> DependencyInput {
        DependencyInput(id: id, role: role, origin: origin, isMarketPrice: price, timeliness: tier, quality: quality,
                        assessment: UsageAssessment(usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "input.policy.v1", reasons: reasons))
    }
    @Test func delayedDependencyStaysDelayedWhileComparisonRemainsAuditOnly() throws {
        let result = try DerivedAssessment(inputs: [input("underlying"), input("option", tier: .delayed), input("providerGreek", role: .comparison, quality: [.stale], reasons: [.staleQuote])],
                                           usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "dependency.v1")
        #expect(!result.allowed && result.marketTimeliness == .delayed)
        #expect(result.reasons.contains(.unsuitableTier) && !result.reasons.contains(.staleQuote))
        #expect(!result.quality.contains(.stale) && result.inputs.count == 3 && result.consumedCount == 2)
    }
    @Test func filingContextAndOptionalExclusionsPreserveCoverage() throws {
        let result = try DerivedAssessment(inputs: [input("price"), input("filing", origin: .filing, price: false, tier: .notApplicable),
                                                    input("optional", role: .excludedOptional(reason: "unavailable", policyRef: "optional.v1"), quality: [.missing])],
                                           usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "dependency.v1")
        #expect(result.allowed && result.marketTimeliness == .realtime)
        #expect(result.origins == [.provider, .filing] && result.excludedCount == 1 && result.consumedCount == 2)
        #expect(throws: ContractError.invalidIdentity) {
            try DerivedAssessment(inputs: [input("optional", role: .excludedOptional(reason: "", policyRef: "v1"))], usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "v1")
        }
    }
    @Test func missingSyntheticAndStaleActualDependenciesBlock() throws {
        for flags in [Set<QualityFlag>([.missing]), [.synthetic], [.stale], [.indicative]] {
            let result = try DerivedAssessment(inputs: [input("actual", quality: flags)], usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "v1")
            #expect(!result.allowed && result.quality == flags)
        }
        let empty = try DerivedAssessment(inputs: [input("comparison", role: .comparison)], usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "v1")
        #expect(empty.reasons == [.missingDependency])
    }
    @Test func assessmentsRemainBoundToTheirUsageAndEvaluationTime() throws {
        let inputs = [input("price")]
        let old = try DerivedAssessment(inputs: inputs, usage: .liveAnalysis, evaluatedAt: fixtureNow, policyRef: "v1")
        let changed = try DerivedAssessment(inputs: inputs, usage: .historicalFill, evaluatedAt: fixtureNow.addingTimeInterval(1), policyRef: "v1")
        #expect(old.allowed && old.evaluatedAt == fixtureNow)
        #expect(!changed.allowed && changed.reasons.contains(.unqualifiedUsage))
    }
    @Test func numericValuesKeepZeroDistinctFromMissingAndUnitsExplicit() throws {
        let p = source(request(.macroSeries))
        let zero = try NumericObservation(recordID: "obs", provenance: p, rawValue: "0", value: Money("0"), state: .available,
                                           unit: .percentPoints, currency: nil, numericPolicyRef: "numeric.v1")
        #expect(zero.value?.decimalString == "0" && zero.rawValue == "0")
        let missing = try NumericObservation(recordID: "obs", provenance: p, rawValue: nil, value: nil, state: .missing,
                                              unit: .percentPoints, currency: nil, numericPolicyRef: "numeric.v1", reasons: ["sourceMissing"])
        #expect(missing.value == nil && missing.state == .missing)
        #expect(throws: ContractError.invalidCoverage) { try NumericObservation(recordID: "obs", provenance: p, rawValue: nil, value: Money("0"), state: .missing, unit: .ratio, currency: nil, numericPolicyRef: "v1", reasons: ["missing"]) }
        #expect(throws: ContractError.invalidIdentity) { try NumericObservation(recordID: "obs", provenance: p, rawValue: "1", value: Money("1"), state: .available, unit: .usd, currency: nil, numericPolicyRef: "v1") }
        #expect(throws: UnavailableReason.specializedPolicyRequired) { try NumericObservation(recordID: "obs", provenance: p, rawValue: "1", value: Money("1"), state: .partial, unit: .ratio, currency: nil, numericPolicyRef: "v1") }
    }
    @Test func chainSkewUsesAllSourceTimesAndMissingIsUnknown() throws {
        let r = request(.optionChain); let underlying = try fixtureQuote(r)
        func chain(_ delta: TimeInterval?) -> SampleChain {
            SampleChain(provenance: source(r), underlyingQuote: underlying,
                        contractProvenances: [source(r, time: delta.map { fixtureNow.addingTimeInterval($0) })])
        }
        #expect(chain(5).maximumQuoteSkew() == 5 && chain(5).meetsLiveSkewPolicy())
        #expect(!chain(5.001).meetsLiveSkewPolicy())
        #expect(chain(nil).maximumQuoteSkew() == nil && !chain(nil).meetsLiveSkewPolicy())
        let mixedCycle = SampleChain(provenance: source(r), underlyingQuote: underlying, contractProvenances: [source(request(.optionChain))])
        #expect(throws: ContractError.mismatchedSource) { try mixedCycle.validateRequestCycle() }
    }
    @Test func computedNumbersRequireExactInputsAndConfigurationWhileInvalidRawTextIsPreserved() throws {
        let r = request(.macroSeries)
        let context = try CalculationContext(calculatedAt: fixtureNow, formulaVersion: "fixture-sum.v1", modelVersion: "fixture.v1",
                                             parameterVersion: "fixture-parameters.v1", inputs: [.init(recordID: "input", provenance: source(r))])
        let computed = try NumericObservation(recordID: "result", provenance: source(r, origin: .derived), rawValue: nil, value: Money("1"),
                                              state: .available, unit: .ratio, currency: nil, numericPolicyRef: "v1", calculation: context)
        #expect(computed.calculation?.inputs.first?.provenance.versionID == "v1")
        #expect(throws: ContractError.invalidIdentity) { try NumericObservation(recordID: "result", provenance: source(r, origin: .derived), rawValue: nil,
            value: Money("1"), state: .available, unit: .ratio, currency: nil, numericPolicyRef: "v1") }
        #expect(throws: ContractError.invalidTime) { try CalculationContext(calculatedAt: fixtureNow.addingTimeInterval(-1), formulaVersion: "v1",
            modelVersion: "v1", parameterVersion: "v1", inputs: [.init(recordID: "input", provenance: source(r))]) }
        let invalid = try NumericObservation(recordID: "obs", provenance: source(r), rawValue: "not-a-number", value: nil, state: .invalid,
                                             unit: .ratio, currency: nil, numericPolicyRef: "v1", reasons: ["parseFailure"])
        #expect(invalid.rawValue == "not-a-number" && invalid.value == nil)
    }
    @Test func importPreviewIsBoundToExactRevisionAndHash() throws {
        let revision = UUID(); let hash = String(repeating: "a", count: 64)
        let token = ImportPreviewToken(id: UUID(), baseRevision: revision, contentHash: hash, mappingVersion: "mapping.v1")
        try token.validate(expectedRevision: revision, expectedHash: hash)
        #expect(throws: ContractError.mismatchedRequest) { try token.validate(expectedRevision: UUID(), expectedHash: hash) }
        #expect(throws: ContractError.mismatchedRequest) { try token.validate(expectedRevision: revision, expectedHash: String(repeating: "b", count: 64)) }
    }
}

private actor ProviderCalls {
    var count = 0
    func record() { count += 1 }
}
private actor ProviderGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation; entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
        }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
private struct TestMarketProvider: MarketDataProvider {
    typealias Bar = SampleRecord
    typealias Expiration = SampleRecord
    typealias Chain = SampleChain
    let id = "fixture"
    var capabilitySnapshot: CapabilitySnapshot { capabilities() }
    let calls: ProviderCalls
    let alterRequest: Bool
    var gate: ProviderGate? = nil
    var chainReply: SampleChain? = nil
    func quote(request original: ProviderRequest) async throws -> ProviderResult<Quote> {
        await calls.record()
        await gate?.suspend()
        let actual = alterRequest ? request(feed: "feed-b") : original
        return try ProviderResult(request: actual, receivedAt: fixtureNow, items: [fixtureQuote(actual)], coverage: .init(expectedCount: 1))
    }
    func bars(request: ProviderRequest) async throws -> ProviderResult<SampleRecord> { throw ProviderFailure.unsupported }
    func optionExpirations(request: ProviderRequest) async throws -> ProviderResult<SampleRecord> { throw ProviderFailure.unsupported }
    func optionChain(request: ProviderRequest) async throws -> ProviderResult<SampleChain> {
        await calls.record()
        guard let chainReply else { throw ProviderFailure.unsupported }
        return try ProviderResult(request: request, receivedAt: fixtureNow, items: [chainReply], coverage: .init(expectedCount: 1))
    }
}
@Suite struct ProviderClientTests {
    @Test func marketClientRejectsCrossFeedUnderlyingAfterDispatch() async throws {
        let r = request(.optionChain), calls = ProviderCalls()
        let wrongFeed = request(.optionChain, id: r.id, feed: "feed-b")
        let bad = SampleChain(provenance: source(r), underlyingQuote: try fixtureQuote(wrongFeed), contractProvenances: [source(r)])
        let provider = TestMarketProvider(calls: calls, alterRequest: false, chainReply: bad)
        await #expect(throws: ContractError.mismatchedSource) { try await MarketDataClient(provider: provider, entitlement: rights()).optionChain(r) }
        #expect(await calls.count == 1)
        let good = SampleChain(provenance: source(r), underlyingQuote: try fixtureQuote(r), contractProvenances: [source(r)])
        let accepted = try await MarketDataClient(provider: TestMarketProvider(calls: calls, alterRequest: false, chainReply: good), entitlement: rights()).optionChain(r)
        #expect(accepted.result.items.first?.underlyingQuote.provenance.feedID == r.feedID)
        #expect(await calls.count == 2)
    }
    @Test func configurationMismatchCannotDispatchEvenWithValidRights() async throws {
        let calls = ProviderCalls(); let provider = TestMarketProvider(calls: calls, alterRequest: false)
        let client = MarketDataClient(provider: provider, entitlement: rights())
        await #expect(throws: ContractError.mismatchedRequest) { try await client.quote(request(configuration: "caps.v2")) }
        #expect(await calls.count == 0)
        let r = request()
        let accepted = try await client.quote(r)
        #expect(accepted.capabilities.version == r.configurationVersion && accepted.entitlement.version == r.entitlementVersion)
        #expect(await calls.count == 1)
    }
    @Test func rightsFailureBlocksDispatchAndChangedFeedIsRejectedAfterDispatch() async throws {
        let calls = ProviderCalls(); let provider = TestMarketProvider(calls: calls, alterRequest: true)
        await #expect(throws: ProviderFailure.notEntitled) { try await MarketDataClient(provider: provider, entitlement: nil).quote(request()) }
        #expect(await calls.count == 0)
        await #expect(throws: ContractError.mismatchedRequest) { try await MarketDataClient(provider: provider, entitlement: rights()).quote(request()) }
        #expect(await calls.count == 1)
    }
    @Test func oneRequestOneExchangePreservesEvidenceAndSource() async throws {
        let calls = ProviderCalls(); let provider = TestMarketProvider(calls: calls, alterRequest: false)
        let r = request()
        let exchange = try await MarketDataClient(provider: provider, entitlement: rights()).quote(r)
        #expect(exchange.result.request == r && exchange.result.status == .complete)
        #expect(exchange.result.items.first?.provenance.requestID == r.id && exchange.entitlement.version == r.entitlementVersion)
        #expect(await calls.count == 1)
    }
    @Test func cancellationDiscardsEvenAnOtherwiseValidLateResponseWithoutRetry() async throws {
        let calls = ProviderCalls(); let gate = ProviderGate()
        let provider = TestMarketProvider(calls: calls, alterRequest: false, gate: gate)
        let client = MarketDataClient(provider: provider, entitlement: rights())
        let task = Task { try await client.quote(request()) }
        await gate.waitUntilEntered(); task.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.count == 1)
    }
}

@Suite struct DataContractClosureTests {
    @Test func endpointCatalogRejectsCredentialLikeAndUnregisteredStringsIncludingDecodedValues() throws {
        for endpoint in ["user:password", "Bearer-synthetic", "bearer-synthetic", "market/quote?token=synthetic", "user@host",
                         "https://host/market/quote", "market/%71uote", "market/quote/synthetic-secret", "unknown/operation", "market/quote\n"] {
            let invalid = source(request(), endpoint: endpoint)
            let decoded = try JSONDecoder().decode(Provenance.self, from: JSONEncoder().encode(invalid))
            #expect(throws: ContractError.invalidEndpoint) { try decoded.validate() }
        }
        for endpoint in EndpointDescriptor.allCases { try source(request(), endpoint: endpoint.rawValue).validate() }
    }
    @Test func chainRejectsDifferentUnderlyingFeedInTheSameCycle() throws {
        let r = request(.optionChain)
        let other = request(.optionChain, id: r.id, feed: "feed-b")
        let chain = SampleChain(provenance: source(r), underlyingQuote: try fixtureQuote(other), contractProvenances: [source(r)])
        #expect(chain.maximumQuoteSkew() == 0) // Time equality does not erase feed identity.
        #expect(throws: ContractError.mismatchedSource) { try chain.validateRequestCycle() }
        #expect(!chain.meetsLiveSkewPolicy())
        let matching = SampleChain(provenance: source(r), underlyingQuote: try fixtureQuote(r), contractProvenances: [source(r)])
        try matching.validateRequestCycle()
        #expect(matching.meetsLiveSkewPolicy())
    }
    @Test func eventWindowAndDecisionCutoffAreSeparateAndBothEnforced() throws {
        let event = utc("2025-03-31T16:00:00Z"), cutoff = utc("2025-05-15T13:00:00Z")
        let r = request(.bars, mode: .asOf(cutoff), range: .sourceEvents(.init(start: event, end: event)))
        try r.validate() // Old event window legitimately does not contain the later cutoff.
        func result(time: Date?, availability: Date = cutoff) throws -> ProviderResult<SampleRecord> {
            try ProviderResult(request: r, receivedAt: fixtureNow,
                items: [SampleRecord(recordID: "bar", provenance: source(r, time: time, availability: .instant(availability, evidence: "release")), value: 1)],
                coverage: .init(expectedCount: 1))
        }
        #expect(try result(time: event).status == .complete)
        #expect(throws: ContractError.invalidRange) { try result(time: event.addingTimeInterval(-0.001)) }
        #expect(throws: ContractError.invalidRange) { try result(time: event.addingTimeInterval(0.001)) }
        #expect(throws: ContractError.invalidRange) { try result(time: nil) }
        #expect(throws: ProviderFailure.pitUnavailable) { try result(time: event, availability: cutoff.addingTimeInterval(0.001)) }
        #expect(throws: ContractError.invalidRange) {
            try request(.bars, mode: .asOf(cutoff), range: .sourceEvents(.init(start: cutoff, end: cutoff.addingTimeInterval(1)))).validate()
        }
    }
    @Test func calendarWindowUsesObservationDatesNotReleaseOrReceiveInstants() throws {
        let day = MarketDate(year: 2025, month: 3, day: 31)
        let cutoff = utc("2025-05-15T13:00:00Z")
        let r = request(.macroSeries, mode: .asOf(cutoff), range: .observationDates(.init(start: day, end: day)))
        try r.validate()
        func result(_ observation: MarketDate?, release: Date = cutoff) throws -> ProviderResult<NumericObservation> {
            let value = try NumericObservation(recordID: "observation", provenance: source(r, time: nil,
                availability: .instant(release, evidence: "version-release"), endpoint: EndpointDescriptor.macroSeries.rawValue,
                observation: observation), rawValue: "1.00", value: Money("1"), state: .available, unit: .ratio, currency: nil, numericPolicyRef: "v1")
            return try ProviderResult(request: r, receivedAt: fixtureNow, items: [value], coverage: .init(expectedCount: 1))
        }
        #expect(try result(day).status == .complete)
        #expect(throws: ContractError.invalidRange) { try result(nil) }
        #expect(throws: ContractError.invalidRange) { try result(.init(year: 2025, month: 3, day: 30)) }
        #expect(throws: ContractError.invalidRange) { try result(.init(year: 2025, month: 4, day: 1)) }
        #expect(throws: ProviderFailure.pitUnavailable) { try result(day, release: cutoff.addingTimeInterval(1)) }
    }
    @Test func dataWindowValidationSurvivesSerializationAndAlsoAppliesToLatest() throws {
        let bad = request(.macroSeries, range: .observationDates(.init(start: .init(year: 2025, month: 4, day: 1), end: .init(year: 2025, month: 3, day: 31))))
        let decoded = try JSONDecoder().decode(ProviderRequest.self, from: JSONEncoder().encode(bad))
        #expect(throws: ContractError.invalidRange) { try decoded.validate() }
        #expect(throws: ContractError.invalidTime) { try MarketDateRange(start: .init(year: 2025, month: 2, day: 30), end: .init(year: 2025, month: 3, day: 1)).validate() }
        let r = request(.bars, range: .sourceEvents(.init(start: fixtureNow, end: fixtureNow)))
        let late = SampleRecord(recordID: "bar", provenance: source(r, time: fixtureNow.addingTimeInterval(1)), value: 1)
        #expect(throws: ContractError.invalidRange) { try ProviderResult(request: r, receivedAt: fixtureNow, items: [late], coverage: .init(expectedCount: 1)) }
        let roundTrip = try JSONDecoder().decode(ProviderRequest.self, from: JSONEncoder().encode(r))
        #expect(roundTrip == r)
    }
    @Test func capabilitySelectsWindowAxisSoCallersCannotSwapClockSemantics() throws {
        let observations = DataWindow.observationDates(.init(start: .init(year: 2025, month: 3, day: 31), end: .init(year: 2025, month: 3, day: 31)))
        let events = DataWindow.sourceEvents(.init(start: fixtureNow, end: fixtureNow))
        for capability in ProviderCapability.allCases {
            let usesObservations = capability == .macroSeries || capability == .companyFacts
            try request(capability, range: usesObservations ? observations : events).validate()
            #expect(throws: ContractError.invalidRequest) { try request(capability, range: usesObservations ? events : observations).validate() }
        }
    }
    @Test func numericSourceIdentityAllowsFormattingButRejectsSilentScaleChangesOrMissingRaw() throws {
        let r = request(.macroSeries)
        func number(raw: String?, value: String, state: ValueState = .available) throws -> NumericObservation {
            try NumericObservation(recordID: "obs", provenance: source(r), rawValue: raw, value: Money(value), state: state,
                                   unit: .ratio, currency: nil, numericPolicyRef: "v1")
        }
        #expect(try number(raw: "1.00", value: "1").value == Money("1"))
        #expect(try number(raw: "-0.00", value: "0").value == Money("0"))
        #expect(throws: ContractError.invalidNormalization) { try number(raw: "1", value: "2") }
        #expect(throws: ContractError.invalidNormalization) { try number(raw: "4", value: "0.04") }
        #expect(throws: ContractError.invalidNormalization) { try number(raw: nil, value: "0") }
        #expect(throws: MoneyError.invalidDecimal) { try number(raw: "not-a-number", value: "0") }
        let context = try CalculationContext(calculatedAt: fixtureNow, formulaVersion: "fixture.v1", modelVersion: "fixture.v1",
                                            parameterVersion: "fixture.v1", inputs: [.init(recordID: "input", provenance: source(r))])
        #expect(throws: ContractError.invalidNormalization) {
            try NumericObservation(recordID: "computed", provenance: source(r, origin: .derived), rawValue: "1", value: Money("2"),
                state: .available, unit: .ratio, currency: nil, numericPolicyRef: "v1", calculation: context)
        }
    }
}
