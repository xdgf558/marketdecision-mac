import Foundation
import CoreDomain
import DataContracts

/// A reported instant share count, not a reviewed complete capital structure.
/// In particular, a DEI cover-date count is not automatically the fiscal-period
/// count or today's count. No split, ADR or multiple-class equivalence is inferred.
public struct SECShareCountCandidate: Sendable, Equatable {
    public let outstandingShares: Money
    public let asOfDate: MarketDate
    public let taxonomy: String
    public let concept: String
    public let accessionNumber: String
    public let form: String
    public let filedDate: MarketDate
    public let availableAt: Date
    public let factID: String
    public let recordID: String
    public let sourceReference: String
    public let sourceVersion: String
    public let sourceHash: String
    public let submissionRecordID: String
    public let submissionSourceReference: String
    public let submissionSourceVersion: String
    public let submissionSourceHash: String
}

/// Read-only selection from an already validated research parent. It deliberately
/// has no Codable representation and confers neither full-class nor valuation eligibility.
public struct SECShareCountCandidateProjection: Sendable, Equatable {
    public enum Status: String, Sendable { case available, missing, conflicting, unsupported }
    public let status: Status
    public let candidates: [SECShareCountCandidate]

    public var candidate: SECShareCountCandidate? {
        status == .available && candidates.count == 1 ? candidates.first : nil
    }

    init(cik: String, facts: [SECCompanyFactRecord], submissions: [SECSubmissionRecord], cutoff: Date) {
        let available = facts.filter { Self.isActualShareConcept($0) && $0.provenance.isAvailable(asOf: cutoff) }
        guard let latestDate = available.map(\.endDate).max() else {
            self.init(status: .missing, candidates: []); return
        }
        // Do not silently fall back to an older valid number when the newest
        // reported instant has unsupported units, dimensions or competing versions.
        let latest = available.filter { $0.endDate == latestDate }
        var selected: [SECCompanyFactRecord] = []
        for versions in Dictionary(grouping: latest, by: \.factID).values {
            guard let first = versions.first,
                  versions.allSatisfy({ $0.cik == first.cik && $0.taxonomy == first.taxonomy
                      && $0.concept == first.concept && $0.unit == first.unit
                      && $0.periodKind == first.periodKind && $0.startDate == first.startDate
                      && $0.dimensions == first.dimensions }),
                  let newest = versions.compactMap({ try? $0.provenance.availability.upperBound() }).max()
            else { self.init(status: .conflicting, candidates: []); return }
            let current = versions.filter { (try? $0.provenance.availability.upperBound()) == newest }
            guard current.count == 1, let fact = current.first else {
                self.init(status: .conflicting, candidates: []); return
            }
            selected.append(fact)
        }
        var projected: [SECShareCountCandidate] = []
        for fact in selected {
            guard fact.cik == cik, fact.periodKind == .instant, fact.startDate == nil,
                  fact.unit == "shares", fact.value.amount > 0,
                  !fact.value.decimalString.contains("."), fact.dimensions.isEmpty,
                  fact.endDate <= fact.filedDate,
                  ["10-K", "10-Q", "10-K/A", "10-Q/A"].contains(fact.form),
                  let sourceReference = fact.provenance.rawObjectRef,
                  let sourceVersion = fact.provenance.versionID,
                  let sourceHash = fact.provenance.rawHash,
                  let factAvailableAt = try? fact.provenance.availability.upperBound()
            else { self.init(status: .unsupported, candidates: []); return }
            let matching = submissions.filter {
                $0.cik == cik && $0.accessionNumber == fact.accessionNumber
                    && $0.provenance.isAvailable(asOf: cutoff)
            }
            guard let newestSubmission = matching.compactMap({ try? $0.provenance.availability.upperBound() }).max()
            else { self.init(status: .unsupported, candidates: []); return }
            let currentSubmissions = matching.filter {
                (try? $0.provenance.availability.upperBound()) == newestSubmission
            }
            guard currentSubmissions.count == 1, let submission = currentSubmissions.first else {
                self.init(status: .conflicting, candidates: []); return
            }
            guard submission.form == fact.form, submission.filingDate == fact.filedDate,
                  let submissionSourceReference = submission.provenance.rawObjectRef,
                  let submissionSourceVersion = submission.provenance.versionID,
                  let submissionSourceHash = submission.provenance.rawHash
            else { self.init(status: .unsupported, candidates: []); return }
            projected.append(SECShareCountCandidate(outstandingShares: fact.value, asOfDate: fact.endDate,
                taxonomy: fact.taxonomy, concept: fact.concept, accessionNumber: fact.accessionNumber,
                form: fact.form, filedDate: fact.filedDate, availableAt: max(factAvailableAt, newestSubmission),
                factID: fact.factID, recordID: fact.recordID, sourceReference: sourceReference,
                sourceVersion: sourceVersion, sourceHash: sourceHash,
                submissionRecordID: submission.recordID, submissionSourceReference: submissionSourceReference,
                submissionSourceVersion: submissionSourceVersion, submissionSourceHash: submissionSourceHash))
        }
        // Equal values from different concepts/contexts are not proof that they
        // describe the same complete share class. Do not pick an alias arbitrarily.
        self.init(status: projected.count == 1 ? .available : .conflicting,
                  candidates: projected.sorted { $0.recordID < $1.recordID })
    }

    private init(status: Status, candidates: [SECShareCountCandidate]) {
        self.status = status; self.candidates = candidates
    }

    private static func isActualShareConcept(_ fact: SECCompanyFactRecord) -> Bool {
        (fact.taxonomy == "dei" && fact.concept == "EntityCommonStockSharesOutstanding")
            || (fact.taxonomy == "us-gaap" && fact.concept == "CommonStockSharesOutstanding")
    }
}
