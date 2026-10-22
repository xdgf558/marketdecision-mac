import Foundation
import CryptoKit
import CoreDomain
import DataContracts

public enum MacroSourceEngine {
    public static let decoderVersion = "macro-offline-source.v1"
    public static let maximumSourceBytes = 4 * 1_024 * 1_024
    public static let maximumObservations = 24_000
    public static func evaluate(_ input: MacroImportInput) throws -> MacroSourceReport {
        do { return try decode(input) }
        catch let error as MacroSourceError { throw error }
        catch { throw MacroSourceError.malformedSource }
    }
    public static func replay(_ report: MacroSourceReport) throws -> MacroSourceReport {
        guard report.schemaVersion == "macro-source-report.v1", report.decoderVersion == decoderVersion else {
            throw MacroSourceError.incompatibleReport
        }
        let rebuilt = try evaluate(report.input)
        guard rebuilt == report else { throw MacroSourceError.incompatibleReport }
        return rebuilt
    }
    public static func contentHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Stable across file revisions and import UUIDs. JSON framing avoids delimiter collisions.
    public static func observationIdentity(descriptor: MacroSourceDescriptor, series: MacroSeriesID, date: String) throws -> String {
        let parts = [descriptor.sourceID, descriptor.feedID, descriptor.basisVersion, descriptor.population ?? "",
                     descriptor.cftcContractCode ?? "", descriptor.cftcScope?.rawValue ?? "", series.rawValue, date]
        return "macro/" + contentHash(try JSONEncoder().encode(parts))
    }
    static func decode(_ input: MacroImportInput) throws -> MacroSourceReport {
        try validate(input)
        let parsed: [ParsedRow]
        switch input.descriptor.format {
        case .fredObservationsJSON, .alfredObservationsJSON: parsed = try FREDMacroDecoder.decode(input)
        case .cboeIndexHistoryCSV, .cboePutCallHistoryCSV: parsed = try CboeMacroDecoder.decode(input)
        case .cftcFinancialFuturesCSV: parsed = try CFTCMacroDecoder.decode(input)
        }
        guard !parsed.isEmpty, parsed.count <= maximumObservations else { throw MacroSourceError.malformedSource }
        let keys = parsed.map(\.releaseKey)
        guard Set(keys).count == keys.count else { throw MacroSourceError.conflictingVersion }
        let releaseKeys = input.releases.map { releaseKey($0.series, $0.observationDate, $0.vintageID) }
        guard Set(releaseKeys).count == releaseKeys.count, Set(releaseKeys).isSubset(of: Set(keys)) else {
            throw MacroSourceError.invalidReleaseEvidence
        }
        let releases = Dictionary(uniqueKeysWithValues: zip(releaseKeys, input.releases))
        var clocks = Set<String>()
        let observations = try parsed.map { row in
            let release = releases[row.releaseKey]
            if let release {
                guard finite(release.releasedAt), finite(release.availableAt), release.releasedAt <= release.availableAt,
                      release.availableAt <= input.retrievedAt, nonblank(release.evidenceReference),
                      try dayStart(row.date) <= release.releasedAt else { throw MacroSourceError.invalidReleaseEvidence }
                // A clipped current-vintage FRED response cannot certify that its value
                // was already known before that source real-time interval began.
                if let start = row.vintageStart { guard try dayStart(start) <= release.availableAt else { throw MacroSourceError.invalidReleaseEvidence } }
                let clock = try contentHash(JSONEncoder().encode([row.series.rawValue, row.date, String(release.availableAt.timeIntervalSinceReferenceDate)]))
                guard clocks.insert(clock).inserted else { throw MacroSourceError.conflictingVersion }
            }
            return MacroSourceObservation(series: row.series,
                observationID: try observationIdentity(descriptor: input.descriptor, series: row.series, date: row.date),
                observationDate: row.date, vintageID: row.vintage, vintageStart: row.vintageStart, vintageEnd: row.vintageEnd,
                unit: row.series.unit, value: row.value, rawFields: row.rawFields, transformation: row.transformation,
                release: release, missingReason: row.missing)
        }.sorted(by: order)
        let selected = select(observations, asOf: input.asOf)
        var gaps: [MacroSourceGap] = []
        for row in observations {
            if let missing = row.missingReason { gaps.append(gap(row, missing)) }
            if row.release == nil { gaps.append(gap(row, .unverifiedRelease)) }
            else if row.release!.availableAt > input.asOf { gaps.append(gap(row, .notAvailableAtCutoff)) }
        }
        return .init(schemaVersion: "macro-source-report.v1", decoderVersion: decoderVersion, input: input,
            contentSHA256: contentHash(input.rawData), observations: observations, selectedObservations: selected, gaps: gaps,
            limitations: [
                "Offline declared source identity, license and release evidence are not supplier approval or independently certified point-in-time history.",
                "Selection only compares explicit availability within the imported collection. Complete source-side revision coverage and strict historical PIT eligibility are not verified.",
                "FRED/ALFRED real-time dates may be query-clipped. They are preserved, not treated as publication or expiry instants, and do not prove revision coverage outside that interval; current-vintage values are not backfilled.",
                "Missing publication evidence stays unavailable. Retrieval time does not establish release time.",
                "Release-cycle macro series remain separately displayed and never enter market-state.v1's closed day/week catalog.",
                "Cboe PCR files describe the explicitly selected Cboe population, not all exchanges. CFTC report dates are position dates, not Friday publication timestamps.",
                "The byte/row budgets are accepted-input limits, not process-memory ceilings; no NAAIM importer or real transport is installed."
            ])
    }
    static func select(_ rows: [MacroSourceObservation], asOf: Date) -> [MacroSourceObservation] {
        // Select only among supplied evidence. A finite FRED vintageEnd can be
        // a query boundary: it does not independently prove a replacement or an
        // expiry instant. Missing source-side history is not certified by this API.
        let groups = Dictionary(grouping: rows, by: \.observationID)
        return groups.values.compactMap { versions in
            let eligible = versions.filter { $0.release.map { $0.availableAt <= asOf } ?? false }
            guard let latest = eligible.max(by: { $0.release!.availableAt < $1.release!.availableAt }) else { return nil }
            // Do not fall back to an older confirmed value past a newer undated revision.
            let ambiguous = versions.contains { row in
                guard row.release == nil else { return false }
                guard let start = row.vintageStart, let latestStart = latest.vintageStart else { return true }
                return start > latestStart && (try? dayStart(start)).map { $0 <= asOf } == true
            }
            return ambiguous ? nil : latest
        }.sorted(by: order)
    }
    static func gap(_ row: MacroSourceObservation, _ reason: MacroSourceGapReason) -> MacroSourceGap {
        .init(series: row.series, observationDate: row.observationDate, vintageID: row.vintageID, reason: reason)
    }
    static func order(_ lhs: MacroSourceObservation, _ rhs: MacroSourceObservation) -> Bool {
        if lhs.series != rhs.series { return lhs.series.rawValue < rhs.series.rawValue }
        if lhs.observationDate != rhs.observationDate { return lhs.observationDate < rhs.observationDate }
        return lhs.vintageID < rhs.vintageID
    }
    static func validate(_ input: MacroImportInput) throws {
        let d = input.descriptor
        guard !input.rawData.isEmpty, input.rawData.count <= maximumSourceBytes,
              finite(input.createdAt), finite(input.retrievedAt), finite(input.asOf),
              input.createdAt >= input.retrievedAt, input.createdAt >= input.asOf,
              !d.series.isEmpty, d.series.count <= 2, Set(d.series).count == d.series.count,
              [d.sourceID,d.feedID,d.basisVersion,d.revisionID,d.sourceReference,d.licenseEvidence].allSatisfy(nonblank),
              input.releases.count <= maximumObservations else { throw MacroSourceError.invalidInput }
        if d.format != .cftcFinancialFuturesCSV {
            guard d.cftcContractCode == nil, d.cftcScope == nil else { throw MacroSourceError.invalidInput }
        }
        switch d.format {
        case .fredObservationsJSON, .alfredObservationsJSON:
            guard d.series.count == 1, FREDMacroDecoder.supported.contains(d.series[0]), d.population == nil else { throw MacroSourceError.unsupportedSeries }
        case .cboeIndexHistoryCSV:
            guard d.series.count == 1, [.vix,.vix3m].contains(d.series[0]), d.population == nil else { throw MacroSourceError.unsupportedSeries }
        case .cboePutCallHistoryCSV:
            guard d.series.count == 1, CboeMacroDecoder.pcrPopulation(d.series[0]) == d.population, d.population != nil else { throw MacroSourceError.unsupportedSeries }
        case .cftcFinancialFuturesCSV:
            guard Set(d.series) == Set([.assetManagerNetOverOI,.leveragedFundsNetOverOI]),
                  let code = d.cftcContractCode, code.range(of: #"^[A-Z0-9]{6}$"#, options: .regularExpression) != nil,
                  let scope = d.cftcScope, d.population == "CFTC:TFF:" + code + ":" + scope.rawValue else { throw MacroSourceError.unsupportedSeries }
        }
    }
    static func finite(_ value: Date) -> Bool { value.timeIntervalSinceReferenceDate.isFinite }
    static func nonblank(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096 }
    static func dayStart(_ text: String) throws -> Date {
        let day = try MarketDate(iso8601: text)
        return try day.start(in: TimeZone(identifier: "America/New_York")!)
    }
    static func isoDay(_ text: String) throws -> String {
        if text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil { _ = try dayStart(text); return text }
        guard text.range(of: #"^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$"#, options: .regularExpression) != nil else { throw MacroSourceError.malformedSource }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[2].count == 4,
              let month = Int(pieces[0]), let day = Int(pieces[1]), let year = Int(pieces[2]) else { throw MacroSourceError.malformedSource }
        let result = String(format: "%04d-%02d-%02d", year, month, day)
        _ = try dayStart(result); return result
    }
    static func releaseKey(_ series: MacroSeriesID, _ date: String, _ vintage: String) -> String { series.rawValue + "|" + date + "|" + vintage }
    struct ParsedRow {
        let series: MacroSeriesID
        let date: String
        let vintage: String
        let vintageStart: String?
        let vintageEnd: String?
        let value: Money?
        let rawFields: [String:String]
        let transformation: String
        let missing: MacroSourceGapReason?
        var releaseKey: String { MacroSourceEngine.releaseKey(series,date,vintage) }
    }
}
