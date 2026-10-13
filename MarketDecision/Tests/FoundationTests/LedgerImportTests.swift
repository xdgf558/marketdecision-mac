import Foundation
import Testing
import CoreDomain
import PortfolioEngine

@Suite("Ledger CSV parsing and explicit mapping")
struct LedgerImportTests {
    @Test func quotedCommaNewlineBOMEscapesAndLogicalRowsRemainExact() throws {
        let raw = Data("\u{feff}when,kind,amount,id,note\r\n2026-01-02T00:00:00Z,DEPOSIT,100,a,\"a,b\r\n\"\"quoted\"\"\"\r\n".utf8)
        let table = try LedgerCSV.parse(raw)
        #expect(table.rows.count == 1)
        #expect(table.rows[0][4] == "a,b\r\n\"quoted\"")
        #expect(table.fileHash == LedgerCSV.hash(raw))
        let mapping = LedgerCSVMapping(fields:[.timestamp:"when",.type:"kind",.amount:"amount",.externalID:"id",.notes:"note"])
        let event = try LedgerCSV.event(table:table,rowIndex:1,accountID:"a",sourceSystem:"synthetic-broker",mapping:mapping)
        #expect(event.source.rowIndex == 1)
        #expect(event.notes == "a,b\r\n\"quoted\"")
    }

    @Test func malformedFilesDoNotProduceAPartialTable() {
        for text in ["", "timestamp,type\n", "a,a\n1,2", "a,b\n1", "a,b\n1,2,3",
                     "a,b\n\"unterminated,2", "a,b\n\"x\"junk,2", "a,b\nno\"quote,2", "a,b\n\n", "a,b\n1,\u{0}"] {
            #expect(throws:(any Error).self) { try LedgerCSV.parse(Data(text.utf8)) }
        }
        #expect(throws:LedgerCSVError.invalidUTF8) { try LedgerCSV.parse(Data([0xff,0xfe])) }
    }

    @Test func headersMappingAndBrokerActionsAreExplicit() throws {
        let data = Data("time,action,cash\n2026-01-02T00:00:00Z,Broker Deposit,12.50\n".utf8)
        let table = try LedgerCSV.parse(data)
        let mapped = LedgerCSVMapping(fields:[.timestamp:"time",.type:"action",.amount:"cash"],actions:["Broker Deposit":.deposit])
        let event = try LedgerCSV.event(table:table,rowIndex:1,accountID:"a",sourceSystem:"broker",mapping:mapped)
        if case .cash(let cash) = event.payload { #expect(cash.amount == (try Money("12.5"))) }
        else { Issue.record("Expected cash") }
        #expect(throws:LedgerCSVError.invalidMapping) { try LedgerCSVMapping.standard.validate(headers:table.headers) }
        #expect(throws:LedgerCSVError.invalidMapping) {
            try LedgerCSVMapping(fields:[.timestamp:"time",.type:"time"]).validate(headers:table.headers)
        }
        let encoded = try JSONEncoder().encode(mapped)
        #expect(try JSONDecoder().decode(LedgerCSVMapping.self,from:encoded) == mapped)
    }

    @Test func noExternalIDUsesFileAndLogicalRowNeverAmountAndDate() throws {
        let raw = Data("timestamp,type,amount\n2026-01-02T00:00:00Z,DEPOSIT,10\n2026-01-02T00:00:00Z,DEPOSIT,10\n".utf8)
        let table = try LedgerCSV.parse(raw)
        let map = LedgerCSVMapping(fields:[.timestamp:"timestamp",.type:"type",.amount:"amount"])
        let a = try LedgerCSV.event(table:table,rowIndex:1,accountID:"A",sourceSystem:"S",mapping:map)
        let b = try LedgerCSV.event(table:table,rowIndex:2,accountID:"A",sourceSystem:"S",mapping:map)
        #expect(try a.idempotencyKey != b.idempotencyKey)
        #expect(a.id != b.id)
        #expect(try a.idempotencyKey != LedgerCSV.event(table:table,rowIndex:1,accountID:"B",sourceSystem:"S",mapping:map).idempotencyKey)
        #expect(try a.idempotencyKey != LedgerCSV.event(table:table,rowIndex:1,accountID:"A",sourceSystem:"Other",mapping:map).idempotencyKey)
    }

    @Test func missingFeeNeverDefaultsToZeroAndNumericLocaleIsNotGuessed() throws {
        func trade(_ fee:String,_ price:String = "10") throws -> LedgerEvent {
            let text = "timestamp,type,symbol,quantity,unit_price,fee,amount,external_id\n2026-01-02T00:00:00Z,BUY_STOCK,DEMO,1,\(price),\(fee),,buy\n"
            return try LedgerCSV.event(table:LedgerCSV.parse(Data(text.utf8)),rowIndex:1,accountID:"a",sourceSystem:"s",mapping:.standard)
        }
        #expect(throws:LedgerError.missingFee) { try trade("") }
        let zero = try trade("0")
        if case .trade(let trade) = zero.payload { #expect(trade.fee == (try Money("0"))) }
        else { Issue.record("Expected trade") }
        for price in ["$10", "1e1", " 10", "10 ", "+10", "NaN"] {
            #expect(throws:(any Error).self) { try trade("0",price) }
        }
    }

    @Test func timestampRequiresActualDateAndExplicitZoneWithoutMillisecondRounding() throws {
        let exact = try LedgerCSV.timestamp("2026-01-02T00:00:00.0004Z")
        let base = try LedgerCSV.timestamp("2026-01-02T00:00:00Z")
        #expect(exact > base)
        #expect(exact < base.addingTimeInterval(0.001))
        #expect(try LedgerCSV.timestamp("2026-01-02T08:00:00+08:00") == base)
        for text in ["2026-02-30T00:00:00Z", "2026-01-02", "2026-01-02T00:00:00", "2026-01-02T24:00:00Z",
                     "2026-01-02T00:00:60Z", "01/02/2026", "2026-01-02T00:00:00+99:00",
                     "2026-01-02T00:00:00Z\n", "2026-01-02T00:00:00.١Z"] {
            #expect(throws:LedgerCSVError.invalidTimestamp) { try LedgerCSV.timestamp(text) }
        }
    }

    @Test func inputBudgetsRejectBeforeAcceptingRows() {
        #expect(throws:LedgerCSVError.budgetExceeded) { try LedgerCSV.parse(Data(repeating:65,count:LedgerCSV.maximumBytes + 1)) }
        #expect(throws:LedgerCSVError.budgetExceeded) {
            try LedgerCSV.parse(Data(("a\n" + String(repeating:"x",count:LedgerCSV.maximumFieldBytes + 1)).utf8))
        }
    }

    @Test func typedPayloadCSVRetainsExplicitTaxCategoryAndRejectsCompetingAmount() throws {
        let payload = LedgerPayload.cash(.init(kind:.otherTax,amount:try Money("2")))
        let json = String(decoding:try JSONEncoder().encode(payload),as:UTF8.self).replacingOccurrences(of:"\"",with:"\"\"")
        let map = LedgerCSVMapping(fields:[.timestamp:"time",.type:"action",.payloadJSON:"payload",.amount:"amount"])
        for conflict in [false,true] {
            let text = "time,action,payload,amount\n2026-01-02T00:00:00Z,PAYLOAD,\"\(json)\",\(conflict ? "2":"")\n"
            let table = try LedgerCSV.parse(Data(text.utf8))
            if conflict {
                #expect(throws:LedgerCSVError.invalidMapping) { try LedgerCSV.event(table:table,rowIndex:1,accountID:"A",sourceSystem:"S",mapping:map) }
            } else { #expect(try LedgerCSV.event(table:table,rowIndex:1,accountID:"A",sourceSystem:"S",mapping:map).payload == payload) }
        }
    }
}
