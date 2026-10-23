import Foundation
import Persistence

/// Navigation metadata only. A catalog row neither opens its retained source bytes nor
/// verifies a financial report, its cached values, or the provider's data eligibility.
public struct SECStockDailyCatalog: Sendable {
    public struct Company: Identifiable, Sendable, Equatable {
        public var id: String { ticker }
        public let ticker: String
        public let companyName: String
        public let cutoff: Date
        public let hasReport: Bool
    }

    public let research: [SECResearchSummary]
    public let reports: [SECFinancialReportSummary]
    public let companies: [Company]
    /// Number of distinct conflicting IDs, counted separately in each catalog. Every
    /// variant of such an ID is omitted; unrelated rows remain available for navigation.
    public let conflictingRecordCount: Int

    public init(ticker: String, research: [SECResearchSummary], reports: [SECFinancialReportSummary]) {
        let sources = Self.unique(research)
        let financials = Self.unique(reports)
        conflictingRecordCount = sources.conflicts + financials.conflicts
        let selected = Self.normalized(ticker)
        self.research = sources.rows.filter { !selected.isEmpty && Self.normalized($0.ticker) == selected }
            .sorted {
                if $0.cutoff != $1.cutoff { return $0.cutoff > $1.cutoff }
                return $0.id.uuidString < $1.id.uuidString
            }
        self.reports = financials.rows.filter { !selected.isEmpty && Self.normalized($0.ticker) == selected }
            .sorted {
                if $0.cutoff != $1.cutoff { return $0.cutoff > $1.cutoff }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        var candidates = sources.rows.map {
            Candidate(ticker: Self.normalized($0.ticker), name: $0.companyName,
                      cutoff: $0.cutoff, recordedAt: $0.cutoff, id: $0.id, isReport: false)
        }
        candidates += financials.rows.map {
            Candidate(ticker: Self.normalized($0.ticker), name: $0.companyName,
                      cutoff: $0.cutoff, recordedAt: $0.createdAt, id: $0.id, isReport: true)
        }
        // Prefer the latest cutoff, then the report's creation time where available.
        // UUID and record kind resolve exact ties without depending on input ordering.
        candidates.sort {
            if $0.cutoff != $1.cutoff { return $0.cutoff > $1.cutoff }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            return !$0.isReport && $1.isReport
        }
        let reportTickers = Set(financials.rows.map { Self.normalized($0.ticker) })
        var seen = Set<String>()
        companies = candidates.compactMap { row -> Company? in
            guard !row.ticker.isEmpty, seen.insert(row.ticker).inserted else { return nil }
            return Company(ticker: row.ticker, companyName: row.name, cutoff: row.cutoff,
                           hasReport: reportTickers.contains(row.ticker))
        }.sorted {
            if $0.cutoff != $1.cutoff { return $0.cutoff > $1.cutoff }
            return $0.ticker < $1.ticker
        }
    }

    private struct Candidate {
        let ticker: String
        let name: String
        let cutoff: Date
        let recordedAt: Date
        let id: UUID
        let isReport: Bool
    }

    private static func normalized(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func unique<Row: Identifiable & Equatable>(_ rows: [Row]) -> (rows: [Row], conflicts: Int)
    where Row.ID == UUID {
        var accepted: [UUID: Row] = [:]
        var conflicts = Set<UUID>()
        for row in rows {
            guard !conflicts.contains(row.id) else { continue }
            if let previous = accepted[row.id], previous != row {
                accepted.removeValue(forKey: row.id)
                conflicts.insert(row.id)
            } else {
                accepted[row.id] = row
            }
        }
        return (Array(accepted.values), conflicts.count)
    }
}
