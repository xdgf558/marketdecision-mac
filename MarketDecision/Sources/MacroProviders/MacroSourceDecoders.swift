import Foundation
import CoreDomain
import DataContracts

/// Official FRED/ALFRED observations output_type=1, complete JSON page only.
/// The FRED rate-curve decoder in PortfolioEngine is intentionally unchanged.
enum FREDMacroDecoder {
    static let supported: Set<MacroSeriesID> = [.fedFunds,.sofr,.dgs2,.dgs10,.treasury10y2y,.cpi,.pce,.corePCE,.unemployment,.payrolls,.realGDP,.highYieldOAS]
    static func decode(_ input: MacroImportInput) throws -> [MacroSourceEngine.ParsedRow] {
        guard let object = try ExactMarketJSON.parse(input.rawData).object,
              object["units"]?.string == "lin", try object["output_type"]?.integer() == 1,
              try object["offset"]?.integer() == 0, let array = object["observations"]?.array,
              try object["count"]?.integer() == array.count, !array.isEmpty,
              array.count <= MacroSourceEngine.maximumObservations else { throw MacroSourceError.malformedSource }
        let series = input.descriptor.series[0]
        if let supplied = object["series_id"] {
            guard supplied.string == series.rawValue else { throw MacroSourceError.unsupportedSeries }
        }
        let parsed: [MacroSourceEngine.ParsedRow] = try array.map { item in
            guard let row = item.object, let date = row["date"]?.string, let start = row["realtime_start"]?.string,
                  let end = row["realtime_end"]?.string, let raw = row["value"]?.string,
                  start <= end else { throw MacroSourceError.malformedSource }
            _ = try MacroSourceEngine.dayStart(date); _ = try MacroSourceEngine.dayStart(start); _ = try MacroSourceEngine.dayStart(end)
            let value = raw == "." ? nil : try Money(raw)
            if let value {
                switch series {
                case .cpi,.pce,.corePCE,.payrolls,.realGDP: guard value.amount > 0 else { throw MacroSourceError.malformedSource }
                case .unemployment: guard value.amount >= 0, value.amount <= 100 else { throw MacroSourceError.malformedSource }
                case .highYieldOAS: guard value.amount >= 0 else { throw MacroSourceError.malformedSource }
                default: break // Native percent/percentage-point rates may legitimately be negative.
                }
            }
            return .init(series: series, date: date, vintage: start + "/" + end, vintageStart: start, vintageEnd: end,
                         value: value, rawFields: ["value":raw], transformation: "source-native-units/lin",
                         missing: value == nil ? .sourceMissingValue : nil)
        }
        // One output_type=1 response describes non-overlapping real-time periods
        // for a given observation. This check is deliberately local to this file:
        // separately downloaded current snapshots may have open-ended intervals.
        for rows in Dictionary(grouping: parsed, by: \.date).values {
            let ordered = rows.sorted { $0.vintageStart! < $1.vintageStart! }
            for i in ordered.indices.dropFirst() {
                guard ordered[i - 1].vintageEnd! < ordered[i].vintageStart! else {
                    throw MacroSourceError.conflictingVersion
                }
            }
        }
        return parsed
    }
}

enum CboeMacroDecoder {
    static func pcrPopulation(_ series: MacroSeriesID) -> String? {
        switch series {
        case .totalPutCall: "CBOE:C1:TOTAL"
        case .indexPutCall: "CBOE:C1:INDEX"
        case .equityPutCall: "CBOE:C1:EQUITY"
        case .etfPutCall: "CBOE:C1:ETP"
        default: nil
        }
    }
    static func decode(_ input: MacroImportInput) throws -> [MacroSourceEngine.ParsedRow] {
        let table = try MacroCSV.parse(input.rawData), series = input.descriptor.series[0]
        let index = input.descriptor.format == .cboeIndexHistoryCSV
        let header = index ? ["DATE","OPEN","HIGH","LOW","CLOSE"] : ["DATE","CALL","PUT","TOTAL","P/C Ratio"]
        guard table.header == header else { throw MacroSourceError.malformedSource }
        return try table.rows.map { fields in
            let date = try MacroSourceEngine.isoDay(fields[0])
            var raw: [String:String] = [:]
            for i in header.indices { raw[header[i]] = fields[i] }
            let value: Money
            if index {
                let open = try Money(fields[1]), high = try Money(fields[2]), low = try Money(fields[3]), close = try Money(fields[4])
                guard low.amount >= 0, low <= open, low <= close, high >= open, high >= close else { throw MacroSourceError.malformedSource }
                value = close
            } else {
                let calls = try MacroCSV.count(fields[1]), puts = try MacroCSV.count(fields[2]), total = try MacroCSV.count(fields[3])
                guard try calls.adding(puts) == total else { throw MacroSourceError.malformedSource }
                value = try Money(fields[4])
                guard value.amount >= 0, calls.amount > 0 else { throw MacroSourceError.malformedSource }
                // Preserve the source's rounded published PCR. Never substitute a
                // recomputed full-precision volume ratio or invent a rounding policy.
            }
            return .init(series: series, date: date, vintage: input.descriptor.revisionID,
                vintageStart: nil, vintageEnd: nil, value: value, rawFields: raw,
                transformation: index ? "Cboe-daily-close/volatility-percent" : "Cboe-published-PCR/ratio",
                missing: nil)
        }
    }
}

enum CFTCMacroDecoder {
    static let required = ["Market_and_Exchange_Names","As_of_Date_In_Form_YYMMDD","Report_Date_as_MM_DD_YYYY",
        "CFTC_Contract_Market_Code","Open_Interest_All","Asset_Mgr_Positions_Long_All","Asset_Mgr_Positions_Short_All",
        "Lev_Money_Positions_Long_All","Lev_Money_Positions_Short_All","FutOnly_or_Combined"]
    static func decode(_ input: MacroImportInput) throws -> [MacroSourceEngine.ParsedRow] {
        let table = try MacroCSV.parse(input.rawData)
        guard Set(required).isSubset(of: Set(table.header)), let code = input.descriptor.cftcContractCode,
              let scope = input.descriptor.cftcScope else { throw MacroSourceError.malformedSource }
        let indexes = Dictionary(uniqueKeysWithValues: table.header.enumerated().map { ($0.element,$0.offset) })
        var result: [MacroSourceEngine.ParsedRow] = []
        for fields in table.rows {
            func field(_ name: String) -> String { fields[indexes[name]!] }
            // Other contracts are retained in raw bytes but are never aggregated.
            guard field("CFTC_Contract_Market_Code") == code else { continue }
            let scopeText = scope == .futuresOnly ? "FutOnly" : "Combined"
            guard field("FutOnly_or_Combined") == scopeText else { throw MacroSourceError.malformedSource }
            let date = try MacroSourceEngine.isoDay(field("Report_Date_as_MM_DD_YYYY"))
            let compact = date.replacingOccurrences(of: "-", with: "").suffix(6)
            guard field("As_of_Date_In_Form_YYMMDD") == compact, MacroSourceEngine.nonblank(field("Market_and_Exchange_Names")) else {
                throw MacroSourceError.malformedSource
            }
            let oi = try MacroCSV.count(field("Open_Interest_All"))
            for series in input.descriptor.series {
                let prefix = series == .assetManagerNetOverOI ? "Asset_Mgr" : "Lev_Money"
                let longName = prefix + "_Positions_Long_All", shortName = prefix + "_Positions_Short_All"
                let long = try MacroCSV.count(field(longName)), short = try MacroCSV.count(field(shortName))
                guard long <= oi, short <= oi else { throw MacroSourceError.malformedSource }
                let value = oi.amount == 0 ? nil : try long.subtracting(short).divided(by: oi.decimalString)
                let raw = Dictionary(uniqueKeysWithValues: required.map { ($0,field($0)) })
                result.append(.init(series: series, date: date, vintage: input.descriptor.revisionID,
                    vintageStart: nil, vintageEnd: nil, value: value, rawFields: raw,
                    transformation: "(" + longName + "-" + shortName + ")/Open_Interest_All;" + Money.numericPolicyVersion,
                    missing: value == nil ? .zeroOpenInterest : nil))
            }
        }
        guard !result.isEmpty else { throw MacroSourceError.unsupportedSeries }
        return result
    }
}

/// Bounded RFC4180-style reader: quoted commas, CRLF, escaped quotes and final
/// newline are accepted; duplicate headers, ragged rows and malformed quotes fail.
enum MacroCSV {
    struct Table { let header: [String]; let rows: [[String]] }
    static func count(_ token: String) throws -> Money {
        let value = try Money(token)
        guard value.amount >= 0, !value.decimalString.contains(".") else { throw MacroSourceError.malformedSource }
        return value
    }
    static func parse(_ data: Data) throws -> Table {
        guard var text = String(data:data,encoding:.utf8), !text.contains("\0") else { throw MacroSourceError.malformedSource }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let bytes = Array(text.utf8)
        var i = 0, field: [UInt8] = [], row: [String] = [], rows: [[String]] = []
        var quoted = false, closedQuote = false
        func decoded(_ value:[UInt8]) throws -> String {
            guard value.count <= 64 * 1024, let text = String(bytes:value,encoding:.utf8) else { throw MacroSourceError.malformedSource }
            return text
        }
        while i < bytes.count {
            let b = bytes[i]
            if quoted {
                if b == 34 {
                    if i+1 < bytes.count, bytes[i+1] == 34 { field.append(34); i += 2; continue }
                    quoted = false; closedQuote = true
                } else { field.append(b) }
                i += 1; continue
            }
            if b == 34 {
                guard field.isEmpty, !closedQuote else { throw MacroSourceError.malformedSource }
                quoted = true; i += 1; continue
            }
            if b == 44 || b == 10 || b == 13 {
                row.append(try decoded(field)); field = []; closedQuote = false
                guard row.count <= 128 else { throw MacroSourceError.malformedSource }
                if b != 44 {
                    if b == 13 { guard i+1 < bytes.count, bytes[i+1] == 10 else { throw MacroSourceError.malformedSource }; i += 1 }
                    rows.append(row); row = []
                    guard rows.count <= MacroSourceEngine.maximumObservations + 1 else { throw MacroSourceError.malformedSource }
                }
                i += 1; continue
            }
            guard !closedQuote else { throw MacroSourceError.malformedSource }
            field.append(b); i += 1
        }
        guard !quoted else { throw MacroSourceError.malformedSource }
        if !field.isEmpty || !row.isEmpty || closedQuote { row.append(try decoded(field)); rows.append(row) }
        guard let header = rows.first, !header.isEmpty, header.allSatisfy({ !$0.isEmpty }), Set(header).count == header.count,
              rows.count > 1, rows.dropFirst().allSatisfy({ $0.count == header.count }) else { throw MacroSourceError.malformedSource }
        return .init(header:header,rows:Array(rows.dropFirst()))
    }
}
