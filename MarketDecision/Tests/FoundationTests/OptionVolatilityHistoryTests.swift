import Foundation
import Testing
import CoreDomain
import DataContracts
import OptionsAnalytics

@Suite struct OptionVolatilityHistoryTests {
    @Test func exact252PriorSessionsProduceUnclampedRankAndStrictPercentile() throws {
        let input = try OptionVolatilityHistoryDemo.input()
        let report = try OptionVolatilityHistoryEngine.calculate(input)
        let count = report.validDays, windowCount = report.window.count, state = report.state, percentile = report.ivPercentile
        #expect(count == 252 && windowCount == 252 && state == .available)
        #expect(percentile == 100)
        let expectedRank: Double = (0.45 - 0.2) / (0.4 - 0.2) * 100
        let actualRank = try requireNumber(report.ivRank)
        #expect(abs(actualRank - expectedRank) < 1e-5)
        #expect(try requireNumber(report.ivRank) > 100)
        #expect(report.window.allSatisfy { $0.session < input.current.input.session })
        #expect(report.researchOnly && report.containsSynthetic)
    }
    @Test func constantHistoryLeavesRankMissingButTiesCountZeroPercentile() throws {
        let report = try OptionVolatilityHistoryEngine.calculate(OptionVolatilityHistoryDemo.input(constantVolatility:0.3))
        #expect(report.state == .constantHistory && report.ivRank == nil && report.ivPercentile == 0)
        #expect(report.historicalMinimum == report.historicalMaximum)
    }
    @Test func historicalTiesExcludedFromPercentileAndCurrentNotInExtrema() throws {
        let original = try OptionVolatilityHistoryDemo.input()
        // Generate exactly the same local IV as the first historical observation.
        let current = try OptionDailyEngine.calculate(OptionDailyDemo.input(at:original.current.input.asOf,nearDays:30,farDays:30,volatility:0.2))
        let input = OptionVolatilityHistoryInput(createdAt:original.createdAt,current:current,history:original.history,calendar:original.calendar)
        let report = try OptionVolatilityHistoryEngine.calculate(input)
        #expect(report.ivPercentile == 0)
        #expect(abs(try requireNumber(report.ivRank)) < 1e-6)
        #expect(abs(try requireNumber(report.historicalMaximum) - 0.4) < 1e-8)
    }
    @Test func shortWindowDoesNotUseStaleTwentyOr126DayThresholds() throws {
        for count in [20,126,251] {
            let report = try OptionVolatilityHistoryEngine.calculate(OptionVolatilityHistoryDemo.input(priorSessions:count))
            #expect(report.state == .insufficientSessions && report.ivRank == nil && report.ivPercentile == nil)
            #expect(report.requiredDays == 252)
        }
    }
    @Test func missingPriorSessionIsNotBackfilledFromOlderReports() throws {
        let original = try OptionVolatilityHistoryDemo.input(priorSessions:253)
        let missing = Array(original.history.dropLast())
        let report = try OptionVolatilityHistoryEngine.calculate(.init(createdAt:original.createdAt,current:original.current,history:missing,calendar:original.calendar))
        #expect(report.state == .missingDay && report.validDays == 251 && report.ivRank == nil)
    }
    @Test func partialDailySummaryCannotQualifyHistory() throws {
        let original = try OptionVolatilityHistoryDemo.input()
        let partialInput = try rewrite(original.history[0].input) { $0["coverage"] = "partial" }
        var history = original.history; history[0] = try OptionDailyEngine.calculate(partialInput)
        let report = try OptionVolatilityHistoryEngine.calculate(.init(createdAt:original.createdAt,current:original.current,history:history,calendar:original.calendar))
        #expect(report.state == .unavailableDailyIV && report.ivRank == nil && report.ivPercentile == nil)
    }
    @Test func excessiveCalendarSpanCannotBeHiddenBy252Rows() throws {
        let original = try OptionVolatilityHistoryDemo.input()
        let oldAt = original.current.input.asOf.addingTimeInterval(-401 * 86_400)
        let old = try OptionDailyEngine.calculate(OptionDailyDemo.input(at:oldAt,nearDays:30,farDays:30))
        let history = [old] + Array(original.history.dropFirst())
        let calendar = OptionDailyCalendar(id:original.calendar.id,version:original.calendar.version,
            sessions:[old.input.session] + Array(original.calendar.sessions.dropFirst()),source:original.calendar.source)
        let report = try OptionVolatilityHistoryEngine.calculate(.init(createdAt:original.createdAt,current:original.current,history:history,calendar:calendar))
        #expect(report.state == .excessiveSpan && report.ivRank == nil)
    }
    @Test(arguments:["duplicateDay","duplicateCalendar","currentIncluded","feed","scope","origin"])
    func ambiguousOrStitchedHistoryRejected(_ mutation:String) throws {
        let original = try OptionVolatilityHistoryDemo.input(priorSessions:2)
        var history=original.history, calendar=original.calendar
        switch mutation {
        case "duplicateDay": history.append(history[0])
        case "duplicateCalendar":
            calendar = .init(id:calendar.id,version:calendar.version,sessions:[calendar.sessions[0]]+calendar.sessions,source:calendar.source)
        case "currentIncluded": history.append(original.current)
        default:
            let input = try rewrite(history[0].input) { dict in
                if mutation == "scope" { dict["declaredScope"] = "OTHER bounded chain" }
                else if mutation == "origin" {
                    var source = dict["source"] as! [String:Any]; source["origin"] = "manual"; dict["source"] = source
                } else {
                    dict["feedID"] = "OTHER"
                    var underlying = dict["underlying"] as! [String:Any]; underlying["feedID"] = "OTHER"; dict["underlying"] = underlying
                    var contracts = dict["contracts"] as! [[String:Any]]
                    for index in contracts.indices { contracts[index]["feedID"] = "OTHER" }; dict["contracts"] = contracts
                }
            }
            history[0] = try OptionDailyEngine.calculate(input)
        }
        #expect(throws:(any Error).self) {
            try OptionVolatilityHistoryEngine.calculate(.init(createdAt:original.createdAt,current:original.current,history:history,calendar:calendar))
        }
    }
    @Test func serializedHistoryReplaysFromFrozenDailyInputsAndRejectsTamperedSummary() throws {
        let result = try OptionVolatilityHistoryEngine.calculate(OptionVolatilityHistoryDemo.input(priorSessions:2))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(OptionVolatilityHistoryReport.self,from:data)
        #expect(try OptionVolatilityHistoryEngine.replay(decoded) == result)
        let corrupt = try rewrite(result) { $0["validDays"] = 252 }
        #expect(throws:OptionDailyError.incompatibleReport) { try OptionVolatilityHistoryEngine.replay(corrupt) }
    }
}
private func rewrite<T:Codable>(_ value:T,_ mutation:(inout [String:Any])->Void)throws->T {
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
    mutation(&object)
    return try JSONDecoder().decode(T.self,from:JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]))
}

private func requireNumber(_ value:Double?)throws->Double { try #require(value) }
