import Foundation
import CryptoKit
import CoreDomain

public enum LedgerCSVError: Error, Equatable, Sendable {
    case invalidUTF8, malformedCSV, emptyFile, duplicateHeader, invalidMapping, budgetExceeded, invalidTimestamp
}

public enum LedgerCSVField: String, Codable, CaseIterable, Sendable {
    case timestamp, type, symbol, quantity, unitPrice, fee, amount, externalID, payloadJSON, providerSequence, rollGroupID, multiLegGroupID, notes
}

public enum LedgerCSVAction: String, Codable, CaseIterable, Sendable {
    case deposit = "DEPOSIT", withdrawal = "WITHDRAWAL", buyStock = "BUY_STOCK", sellStock = "SELL_STOCK"
    case dividend = "DIVIDEND", interest = "INTEREST", fee = "FEE", payload = "PAYLOAD"
    case dividendWithholding = "DIVIDEND_WITHHOLDING", interestWithholding = "INTEREST_WITHHOLDING", otherTax = "OTHER_TAX"
}

/// Mappings are explicit and persisted with original bytes. No locale/date/fee guessing.
public struct LedgerCSVMapping: Codable, Equatable, Sendable {
    public static let version = "ledger-csv-map.v1"
    public static let normalizationVersion = "ledger-csv-normalization.v1"
    public let fields: [LedgerCSVField: String]
    public let actions: [String: LedgerCSVAction]
    public init(fields: [LedgerCSVField: String], actions: [String: LedgerCSVAction] = Dictionary(uniqueKeysWithValues: LedgerCSVAction.allCases.map { ($0.rawValue, $0) })) {
        self.fields = fields; self.actions = actions
    }
    private enum CodingKeys: String, CodingKey { case fields, actions }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy:CodingKeys.self)
        let names = try container.decode([String:String].self,forKey:.fields)
        var fields:[LedgerCSVField:String] = [:]
        for (name,value) in names {
            guard let field = LedgerCSVField(rawValue:name) else { throw LedgerCSVError.invalidMapping }
            fields[field] = value
        }
        self.fields = fields; actions = try container.decode([String:LedgerCSVAction].self,forKey:.actions)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy:CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue,$0.value) }),forKey:.fields)
        try container.encode(actions,forKey:.actions)
    }
    public static let standard = LedgerCSVMapping(fields: [.timestamp:"timestamp", .type:"type", .symbol:"symbol",
        .quantity:"quantity", .unitPrice:"unit_price", .fee:"fee", .amount:"amount", .externalID:"external_id"])
    public static let standardTemplate = "timestamp,type,symbol,quantity,unit_price,fee,amount,external_id\n2026-01-02T14:30:00Z,DEPOSIT,,,,,1000,example-deposit\n2026-01-02T14:31:00Z,BUY_STOCK,DEMO,2,10,0,,example-buy\n"
    public func validate(headers: [String]) throws {
        guard fields[.timestamp] != nil, fields[.type] != nil, !actions.isEmpty,
              !actions.keys.contains(where: { $0.isEmpty || $0.contains("\0") }),
              Set(fields.values).count == fields.count,
              fields.values.allSatisfy({ headers.contains($0) }) else { throw LedgerCSVError.invalidMapping }
    }
}

public struct LedgerCSVTable: Sendable, Equatable {
    public let headers: [String]
    /// Logical data rows, starting at rowIndex 1; quoted line breaks do not invent identities.
    public let rows: [[String]]
    public let fileHash: String
}

public enum LedgerCSV {
    // Input budgets bound accepted data, not process RSS or transient String copies.
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumRows = 10_000
    public static let maximumColumns = 128
    public static let maximumFieldBytes = 65_536

    public static func parse(_ data: Data) throws -> LedgerCSVTable {
        guard data.count <= maximumBytes else { throw LedgerCSVError.budgetExceeded }
        guard String(data: data, encoding: .utf8) != nil else { throw LedgerCSVError.invalidUTF8 }
        let bytes = Array(data)
        var cursor = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        var field: [UInt8] = [], row: [String] = [], records: [[String]] = []
        var quoted = false, closedQuote = false, rowStarted = false
        func appendField() throws {
            guard row.count < maximumColumns, let value = String(bytes: field, encoding: .utf8) else { throw LedgerCSVError.budgetExceeded }
            row.append(value); field.removeAll(keepingCapacity: true); closedQuote = false
        }
        func appendRow() throws {
            try appendField()
            guard records.count <= maximumRows else { throw LedgerCSVError.budgetExceeded }
            records.append(row); row.removeAll(keepingCapacity: true); rowStarted = false
        }
        while cursor < bytes.count {
            let byte = bytes[cursor]
            guard byte != 0 else { throw LedgerCSVError.malformedCSV }
            if quoted {
                if byte == 34 {
                    if cursor + 1 < bytes.count, bytes[cursor + 1] == 34 { field.append(34); cursor += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(byte) }
            } else if byte == 44 {
                try appendField(); rowStarted = true
            } else if byte == 10 || byte == 13 {
                try appendRow()
                if byte == 13, cursor + 1 < bytes.count, bytes[cursor + 1] == 10 { cursor += 1 }
            } else if byte == 34 {
                guard field.isEmpty, !closedQuote else { throw LedgerCSVError.malformedCSV }
                quoted = true; rowStarted = true
            } else {
                guard !closedQuote else { throw LedgerCSVError.malformedCSV }
                field.append(byte); rowStarted = true
            }
            guard field.count <= maximumFieldBytes else { throw LedgerCSVError.budgetExceeded }
            cursor += 1
        }
        guard !quoted else { throw LedgerCSVError.malformedCSV }
        if rowStarted || !row.isEmpty || !field.isEmpty || closedQuote { try appendRow() }
        guard let headers = records.first, !headers.isEmpty,
              headers.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              records.count > 1 else { throw LedgerCSVError.emptyFile }
        guard Set(headers).count == headers.count else { throw LedgerCSVError.duplicateHeader }
        guard records.dropFirst().allSatisfy({ $0.count == headers.count }) else { throw LedgerCSVError.malformedCSV }
        return LedgerCSVTable(headers: headers, rows: Array(records.dropFirst()), fileHash: hash(data))
    }

    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func event(table: LedgerCSVTable, rowIndex: Int, accountID: String, sourceSystem: String,
                             mapping: LedgerCSVMapping) throws -> LedgerEvent {
        try mapping.validate(headers: table.headers)
        guard rowIndex > 0, rowIndex <= table.rows.count else { throw LedgerCSVError.invalidMapping }
        let row = table.rows[rowIndex - 1]
        func value(_ field: LedgerCSVField) -> String {
            guard let header = mapping.fields[field], let column = table.headers.firstIndex(of: header) else { return "" }
            return row[column]
        }
        func optional(_ field: LedgerCSVField) -> String? { value(field).isEmpty ? nil : value(field) }
        func rejectNonempty(_ fields: [LedgerCSVField]) throws {
            guard fields.allSatisfy({ value($0).isEmpty }) else { throw LedgerCSVError.invalidMapping }
        }
        guard let action = mapping.actions[value(.type)] else { throw LedgerCSVError.invalidMapping }
        let source = LedgerSource(sourceSystem: sourceSystem, externalTransactionID: optional(.externalID),
            fileHash: table.fileHash, rowIndex: rowIndex, evidence: LedgerCSVMapping.normalizationVersion)
        let identity = try source.identity(accountID: accountID)
        let id = "csv-" + hash(Data(identity.utf8))
        let payload: LedgerPayload
        switch action {
        case .buyStock, .sellStock:
            try rejectNonempty([.amount, .payloadJSON])
            guard !value(.fee).isEmpty else { throw LedgerError.missingFee }
            let symbol = value(.symbol)
            guard symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,14}\z"#, options: .regularExpression) != nil else { throw LedgerError.invalidIdentity }
            payload = .trade(LedgerTrade(instrument: .equity(.init(id: symbol, symbol: symbol)),
                side: action == .buyStock ? .buy : .sell, effect: action == .buyStock ? .open : .close,
                quantity: try Money(value(.quantity)), unitPrice: try Money(value(.unitPrice)), fee: try Money(value(.fee)),
                openingLotID: action == .buyStock ? id + "-lot" : nil))
        case .payload:
            try rejectNonempty([.amount,.symbol,.quantity,.unitPrice,.fee])
            payload = try JSONDecoder().decode(LedgerPayload.self, from: Data(value(.payloadJSON).utf8))
        default:
            try rejectNonempty([.quantity,.unitPrice,.fee,.payloadJSON])
            let kind: LedgerCashKind
            switch action {
            case .deposit: kind = .deposit
            case .withdrawal: kind = .withdrawal
            case .dividend: kind = .dividend
            case .interest: kind = .interest
            case .fee: kind = .fee
            case .dividendWithholding: kind = .dividendWithholding
            case .interestWithholding: kind = .interestWithholding
            case .otherTax: kind = .otherTax
            default: throw LedgerCSVError.invalidMapping
            }
            payload = .cash(.init(kind: kind, amount: try Money(value(.amount)), securityID: optional(.symbol)))
        }
        let sequence: Int?
        if let raw = optional(.providerSequence) {
            guard raw.range(of: #"^(0|[1-9][0-9]*)\z"#,options: .regularExpression) != nil, let parsed = Int(raw) else { throw LedgerError.invalidIdentity }
            sequence = parsed
        } else { sequence = nil }
        let event = LedgerEvent(id: id, accountID: accountID, effectiveAt: try timestamp(value(.timestamp)),
            providerSequence: sequence, source: source, payload: payload,
            rollGroupID: optional(.rollGroupID), multiLegGroupID: optional(.multiLegGroupID), notes: value(.notes))
        try event.validate(); return event
    }

    /// RFC3339 with explicit zone. Preserve the Date precision rather than rounding to milliseconds.
    public static func timestamp(_ text: String) throws -> Date {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { throw LedgerCSVError.invalidTimestamp }
        func part(_ index: Int) -> String { match.range(at:index).location == NSNotFound ? "" : ns.substring(with: match.range(at:index)) }
        let values = (1...6).compactMap { Int(part($0)) }
        guard values.count == 6, values[0] >= 1, values[3] < 24, values[4] < 60, values[5] < 60 else { throw LedgerCSVError.invalidTimestamp }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year:values[0],month:values[1],day:values[2],hour:values[3],minute:values[4],second:values[5])
        guard let base = calendar.date(from: components), calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from:base) == components else { throw LedgerCSVError.invalidTimestamp }
        let zone = part(8); var offset = 0
        if zone != "Z" {
            let numbers = zone.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] <= 23, numbers[1] < 60 else { throw LedgerCSVError.invalidTimestamp }
            offset = (numbers[0] * 3_600 + numbers[1] * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        let fraction = part(7)
        guard let seconds = Double(fraction.isEmpty ? "0" : "0." + fraction) else { throw LedgerCSVError.invalidTimestamp }
        return base.addingTimeInterval(seconds - Double(offset))
    }
}
