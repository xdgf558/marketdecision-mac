import Foundation
import CoreDomain

/// Synthetic raw HTTP-shaped fixture, never an observed quote or a supplier entitlement.
public enum OptionChainDemo {
    public static let time = Date(timeIntervalSince1970: 1_792_094_400) // 2026-10-15 20:00Z
    public static let symbol = "DEMO"
    public static let expirations = [MarketDate(year: 2026, month: 11, day: 13), MarketDate(year: 2026, month: 11, day: 20)]
    public static var rights: OptionChainRights {
        .init(version: "synthetic-rights.v1", evidenceRef: "synthetic-option-chain-fixture", licenseRef: "synthetic-only",
              validFrom: time.addingTimeInterval(-3600), validThrough: time.addingTimeInterval(3600),
              capabilities: [.quote, .optionExpirations, .optionChain], usages: [.replay])
    }
    public static func body(capability: ProviderCapability, expiration: MarketDate? = nil) throws -> Data {
        let timestamp = Int(time.timeIntervalSince1970 * 1000)
        switch capability {
        case .quote:
            return Data("{\"quotes\":{\"quote\":{\"symbol\":\"DEMO\",\"type\":\"stock\",\"bid\":99.95,\"ask\":100.05,\"bidsize\":100,\"asksize\":100,\"bid_date\":\(timestamp),\"ask_date\":\(timestamp)}}}".utf8)
        case .optionExpirations:
            return Data(#"{"expirations":{"date":["2026-11-13","2026-11-20"]}}"#.utf8)
        case .optionChain:
            guard let expiration, expirations.contains(expiration) else { throw ContractError.invalidRange }
            let stamp = expiration == expirations[0] ? "261113" : "261120"
            let prices = expiration == expirations[0] ? ["3.10", "2.80", "1.20", "5.90"] : ["3.50", "3.10", "1.50", "6.20"]
            var records: [String] = []
            for index in 0..<4 {
                let right = index % 2 == 0 ? "call" : "put", sign = index % 2 == 0 ? "C" : "P"
                let strike = index < 2 ? 100 : 105, strikeID = index < 2 ? "00100000" : "00105000"
                let ask = try Money(prices[index]).adding(Money("0.10")).decimalString
                records.append("{\"symbol\":\"DEMO\(stamp)\(sign)\(strikeID)\",\"type\":\"option\",\"underlying\":\"DEMO\",\"expiration_date\":\"\(expiration.iso8601)\",\"option_type\":\"\(right)\",\"strike\":\(strike),\"contract_size\":100,\"bid\":\(prices[index]),\"ask\":\(ask),\"bidsize\":10,\"asksize\":12,\"bid_date\":\(timestamp),\"ask_date\":\(timestamp),\"volume\":100,\"open_interest\":300}")
            }
            return Data(("{\"options\":{\"option\":[" + records.joined(separator: ",") + "]}}").utf8)
        default: throw ProviderFailure.unsupported
        }
    }
    public static func capture(id: UUID = UUID()) throws -> OptionChainCapture {
        let pages = try ([ProviderCapability.quote, .optionExpirations] + expirations.map { _ in ProviderCapability.optionChain })
            .enumerated().map { index, capability in
                let expiry = index < 2 ? nil : expirations[index - 2]
                return OptionChainRawPage(request: .init(id: id, providerID: "tradier", feedID: OptionChainEnvironment.sandbox.feedID,
                    resourceID: symbol, capability: capability, mode: .latest, usage: .replay,
                    configurationVersion: OptionChainCapture.configurationVersion, entitlementVersion: rights.version, requestedAt: time),
                    expiration: expiry, receivedAt: time.addingTimeInterval(Double(index + 1)), statusCode: 200,
                    bytes: try body(capability: capability, expiration: expiry))
            }
        return try OptionChainCapture(id: id, createdAt: time.addingTimeInterval(4), requestedAt: time, symbol: symbol,
            environment: .sandbox, timestampUnit: .unixMilliseconds, synthetic: true, rights: rights,
            requestedExpirations: expirations, pages: pages)
    }
}
