import Foundation
import CoreDomain
import MarketAnalytics

/// Converts explicitly selected, replayed files into the existing market-state.v1
/// input vocabulary. It never modifies its catalog or grants provider/PIT rights.
/// Selection is limited to imported release evidence, not certified complete
/// source-side real-time history; native date intervals are not expiry clocks.
public enum MacroSourceBridge {
    public static func build(reports: [MacroSourceReport], asOf: Date) throws -> MacroSourceBridgeResult {
        guard MacroSourceEngine.finite(asOf), reports.count <= 100 else { throw MacroSourceError.invalidInput }
        var groups: [MacroSeriesID:(MacroImportInput,[MacroSourceObservation])] = [:]
        var gaps: [MacroSourceGap] = [], transformations = Set<String>()
        for report in reports {
            _ = try MacroSourceEngine.replay(report)
            for series in report.input.descriptor.series {
                let rows = report.observations.filter { $0.series == series }
                guard series.marketKey != nil else {
                    gaps += rows.map { MacroSourceEngine.gap($0,.noMarketMapping) }; continue
                }
                if let old = groups[series] {
                    guard compatible(old.0,report.input) else { throw MacroSourceError.conflictingVersion }
                    groups[series] = (old.0,try merge(old.1,rows))
                } else { groups[series] = (report.input,rows) }
            }
        }
        var output: [MarketSeries] = []
        for series in groups.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let (input,rows) = groups[series], let key = series.marketKey else { throw MacroSourceError.invalidInput }
            let selected = MacroSourceEngine.select(rows,asOf:asOf)
            let selectedMap = Dictionary(uniqueKeysWithValues: selected.map { ($0.observationID,$0) })
            var observations: [MarketObservation] = [], clocks = Set<String>()
            for row in rows.sorted(by: MacroSourceEngine.order) {
                guard let release = row.release else { gaps.append(MacroSourceEngine.gap(row,.unverifiedRelease)); continue }
                guard release.availableAt <= asOf else { gaps.append(MacroSourceEngine.gap(row,.notAvailableAtCutoff)); continue }
                // MarketStateObservation has no tombstone. Conservatively omit all
                // versions of an observation with a selected missing value or an
                // ambiguous undated replacement, instead of reviving its old value.
                guard let latest = selectedMap[row.observationID], latest.value != nil,
                      let value = row.value else {
                    gaps.append(MacroSourceEngine.gap(row,row.missingReason ?? .unverifiedRelease)); continue
                }
                let normalized = series == .highYieldOAS ? try value.multiplied(by: "100") : value
                let conversion = series == .highYieldOAS ? "percent-to-basis-points:x100" : "native-unit:" + row.unit.rawValue
                transformations.insert(series.rawValue + ":" + conversion)
                let clock = row.observationID + ":" + String(release.availableAt.timeIntervalSinceReferenceDate)
                guard clocks.insert(clock).inserted else { throw MacroSourceError.conflictingVersion }
                observations.append(.init(observationID:row.observationID,vintageID:row.observationID + "/" + row.vintageID,
                    observationDate:row.observationDate,releasedAt:release.releasedAt,availableAt:release.availableAt,
                    value:normalized,rawValue:normalized.decimalString))
            }
            guard !observations.isEmpty else { continue }
            let descriptor = input.descriptor
            output.append(.init(key:key,unit:key.unit,frequency:series.frequency == .weekly ? .weekly : .daily,
                origin:input.origin == .synthetic ? .synthetic : .manual,sourceID:descriptor.sourceID,feedID:descriptor.feedID,
                methodology:MacroSourceEngine.decoderVersion + "; offline-normalized bridge; native tokens/release evidence remain in frozen source report; " +
                    (series == .highYieldOAS ? "percent-to-basis-points:x100" : "native output units"),
                population:descriptor.population,basisVersion:descriptor.basisVersion,observations:observations))
        }
        return .init(series:output,gaps:gaps,transformations:transformations.sorted())
    }
    static func compatible(_ lhs: MacroImportInput,_ rhs: MacroImportInput) -> Bool {
        let a=lhs.descriptor,b=rhs.descriptor
        return lhs.origin == rhs.origin && a.format == b.format && a.sourceID == b.sourceID && a.feedID == b.feedID &&
            a.basisVersion == b.basisVersion && a.population == b.population && a.cftcContractCode == b.cftcContractCode && a.cftcScope == b.cftcScope
    }
    static func merge(_ lhs:[MacroSourceObservation],_ rhs:[MacroSourceObservation]) throws -> [MacroSourceObservation] {
        var byVersion = Dictionary(uniqueKeysWithValues:lhs.map { ($0.observationID+"/"+$0.vintageID,$0) })
        for row in rhs {
            let identity=row.observationID+"/"+row.vintageID
            if let old=byVersion[identity] {
                guard old.series == row.series, old.observationDate == row.observationDate, old.vintageStart == row.vintageStart,
                      old.vintageEnd == row.vintageEnd, old.value == row.value, old.unit == row.unit,
                      old.rawFields == row.rawFields, old.transformation == row.transformation, old.missingReason == row.missingReason,
                      old.release == nil || row.release == nil || old.release == row.release else { throw MacroSourceError.conflictingVersion }
                if old.release == nil, row.release != nil { byVersion[identity]=row }
            } else { byVersion[identity]=row }
        }
        return byVersion.values.sorted(by:MacroSourceEngine.order)
    }
}
