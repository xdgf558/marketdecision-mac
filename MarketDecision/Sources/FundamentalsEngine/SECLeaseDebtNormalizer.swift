import Foundation
import CoreDomain
import DataContracts

/// Evidence-v2-only bridge from exact current/noncurrent lease liabilities to the existing
/// mutually exclusive total slots. Missing parts, incompatible filings and rejected aliases
/// cannot become zero or be rescued by an arbitrary alternative.
enum SECLeaseDebtNormalizer {
    private struct Lease {
        let name, totalConcept, totalField, currentField, noncurrentField: String
    }
    private static let leases = [
        Lease(name: "finance", totalConcept: "FinanceLeaseLiability", totalField: "debt.finance-lease-total",
              currentField: "lease-components.finance-current", noncurrentField: "lease-components.finance-noncurrent"),
        Lease(name: "operating", totalConcept: "OperatingLeaseLiability", totalField: "debt.operating-lease-total",
              currentField: "lease-components.operating-current", noncurrentField: "lease-components.operating-noncurrent")
    ]

    static func complete(_ reported: FinancialNormalizationResult,
                         sourceFacts: [SECCompanyFactRecord]) throws -> FinancialNormalizationResult {
        guard reported.dictionaryVersion == "financial-fields.us-gaap.completion.v2" else {
            throw SECFinancialError.unsupportedFormat
        }
        let componentFields = Set(leases.flatMap { [$0.currentField, $0.noncurrentField] })
        // Component bytes stay in evidence.facts. Calculation input keeps only total slots,
        // so a derived total never duplicates its own sources as another debt input.
        var output = reported.values.filter { !componentFields.contains($0.fieldID) }
        var issues = reported.issues
        let blockedIDs = Set(reported.issues.filter { $0.severity == .blocker }.flatMap(\.factIDs))
        for lease in leases {
            let relevant = reported.values.filter { $0.fieldID == lease.totalField
                || $0.fieldID == lease.currentField || $0.fieldID == lease.noncurrentField }
            let grouped = Dictionary(grouping: relevant) { $0.cik + "|" + $0.periodEnd.iso8601 }
            for key in grouped.keys.sorted() {
                guard let rows = grouped[key], let basis = rows.first else { continue }
                let totals = rows.filter { $0.fieldID == lease.totalField }
                let current = rows.filter { $0.fieldID == lease.currentField }
                let noncurrent = rows.filter { $0.fieldID == lease.noncurrentField }
                guard !current.isEmpty || !noncurrent.isEmpty else { continue }
                let relatedIDs = Array(Set(rows.flatMap(\.sourceFactIDs))).sorted()
                // A conflicting or ambiguous reported total stays rejected; a valid-looking
                // pair must not erase an upstream rejection of the same total and period.
                let rejectedTotals = sourceFacts.filter {
                    $0.taxonomy == "us-gaap" && $0.concept == lease.totalConcept && $0.unit == "USD"
                        && $0.cik == basis.cik && $0.endDate == basis.periodEnd
                        && (blockedIDs.contains($0.factID) || blockedIDs.contains($0.recordID))
                }
                guard rejectedTotals.isEmpty else {
                    let rejected = Set(totals.map(\.id))
                    output.removeAll { rejected.contains($0.id) }
                    issues.append(.init(code: "lease-total-rejected", severity: .blocker,
                        factIDs: Array(Set(relatedIDs + rejectedTotals.map(\.factID))).sorted(),
                        message: lease.name + " lease total has conflicting source evidence; components did not replace it."))
                    continue
                }
                guard current.count == 1, noncurrent.count == 1 else {
                    if totals.isEmpty {
                        issues.append(.init(code: "lease-components-incomplete", severity: .medium,
                            factIDs: relatedIDs, message: lease.name + " lease total requires both current and noncurrent liabilities; absence was not zero."))
                    }
                    continue
                }
                let first = current[0], second = noncurrent[0]
                guard validComponent(first), validComponent(second), sameBasis(first, second),
                      sameSource(first, second, facts: sourceFacts),
                      Set(first.sourceFactIDs).isDisjoint(with: Set(second.sourceFactIDs)) else {
                    if totals.isEmpty {
                        issues.append(.init(code: "lease-components-incompatible", severity: .high,
                            factIDs: relatedIDs, message: lease.name + " lease components need nonnegative values from the same filing, period and source response."))
                    }
                    continue
                }
                let total = try first.value.adding(second.value)
                if let direct = totals.first {
                    // Different filings cannot establish agreement or conflict. Retain the
                    // independently reported total; do not mix it with this component pair.
                    if sameBasis(direct, first), sameSource(direct, first, facts: sourceFacts),
                       direct.value != total {
                        output.removeAll { $0.id == direct.id }
                        issues.append(.init(code: "lease-total-components-conflict", severity: .blocker,
                            factIDs: relatedIDs, message: lease.name + " reported lease total disagrees with the complete same-filing current and noncurrent components."))
                    }
                    continue
                }
                let versions = Array(Set(first.sourceVersions + second.sourceVersions)).sorted()
                let sourceIDs = Array(Set(first.sourceFactIDs + second.sourceFactIDs)).sorted()
                let identity = [lease.totalField, first.cik, first.periodEnd.iso8601, reported.dictionaryVersion] + versions + sourceIDs
                output.append(NormalizedFinancialFact(id: "sec-lease-total/" + digest(Data(identity.joined(separator: "|").utf8)),
                    cik: first.cik, fieldID: lease.totalField, statement: .balanceSheet, nature: .instant,
                    periodType: .instant, periodStart: nil, periodEnd: first.periodEnd, fiscalYear: nil, fiscalPeriod: nil,
                    unit: "USD", value: total, sourceValue: nil, derivation: .leaseComponentsSum,
                    sourceFactIDs: sourceIDs, sourceVersions: versions, accessionNumbers: first.accessionNumbers,
                    dictionaryVersion: reported.dictionaryVersion, availableAt: max(first.availableAt, second.availableAt),
                    confidence: .medium, limitations: Array(Set(first.limitations + second.limitations
                        + ["SEC_SAME_FILING_LEASE_COMPONENT_SUM", "derived-from-explicit-components"])).sorted()))
            }
        }
        return FinancialNormalizationResult(asOf: reported.asOf, dictionaryVersion: reported.dictionaryVersion,
            values: output.sorted { $0.periodEnd == $1.periodEnd ? $0.id < $1.id : $0.periodEnd < $1.periodEnd },
            issues: issues, selectedSourceFacts: reported.selectedSourceFacts, unmappedSourceFacts: reported.unmappedSourceFacts)
    }

    private static func validComponent(_ value: NormalizedFinancialFact) -> Bool {
        value.statement == .balanceSheet && value.nature == .instant && value.periodType == .instant
            && value.periodStart == nil && value.unit == "USD" && value.value.amount >= 0
            && value.derivation == .reported && value.accessionNumbers.count == 1
            && value.sourceFactIDs.count == 1 && value.sourceVersions.count == 1
    }

    private static func sameBasis(_ lhs: NormalizedFinancialFact, _ rhs: NormalizedFinancialFact) -> Bool {
        lhs.cik == rhs.cik && lhs.periodEnd == rhs.periodEnd && lhs.periodStart == nil && rhs.periodStart == nil
            && lhs.unit == rhs.unit && lhs.dictionaryVersion == rhs.dictionaryVersion
            && lhs.accessionNumbers.count == 1 && lhs.accessionNumbers == rhs.accessionNumbers
    }

    private static func sameSource(_ lhs: NormalizedFinancialFact, _ rhs: NormalizedFinancialFact,
                                   facts: [SECCompanyFactRecord]) -> Bool {
        func source(_ value: NormalizedFinancialFact) -> SECCompanyFactRecord? {
            let matches = facts.filter { value.sourceFactIDs.contains($0.factID)
                && $0.provenance.versionID.map { value.sourceVersions.contains($0) } == true }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let a = source(lhs)?.provenance, let b = source(rhs)?.provenance,
              a.rawHash != nil, a.rawObjectRef != nil else { return false }
        return a.providerID == b.providerID && a.feedID == b.feedID && a.rawHash == b.rawHash
            && a.rawObjectRef == b.rawObjectRef && a.endpointDescriptor == b.endpointDescriptor
            && a.normalizationVersion == b.normalizationVersion && a.licenseRef == b.licenseRef
    }
}
