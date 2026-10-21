import Foundation

/// Fabricated format fixtures, never downloaded market observations or release evidence.
public enum MacroSourceDemo {
    public static func input(format: MacroSourceFormat = .fredObservationsJSON) throws -> MacroImportInput {
        let now = try instant("2026-10-19T21:00:00Z")
        let series: [MacroSeriesID], raw: String, population: String?, code: String?, scope: CFTCReportScope?
        var releases: [MacroReleaseEvidence] = []
        let revision="SYNTHETIC-file-v1"
        switch format {
        case .fredObservationsJSON:
            series=[.cpi]; population=nil; code=nil; scope=nil
            raw=#"{"units":"lin","output_type":1,"offset":0,"count":2,"observations":[{"date":"2026-08-01","realtime_start":"2026-09-10","realtime_end":"9999-12-31","value":"321.100"},{"date":"2026-09-01","realtime_start":"2026-10-13","realtime_end":"9999-12-31","value":"322.250"}]}"#
            releases=[try release(.cpi,"2026-08-01","2026-09-10/9999-12-31","2026-09-10T13:00:00Z"),
                      try release(.cpi,"2026-09-01","2026-10-13/9999-12-31","2026-10-13T13:00:00Z")]
        case .alfredObservationsJSON:
            series=[.highYieldOAS]; population=nil; code=nil; scope=nil
            raw=#"{"units":"lin","output_type":1,"offset":0,"count":2,"observations":[{"date":"2026-10-16","realtime_start":"2026-10-16","realtime_end":"2026-10-18","value":"3.500"},{"date":"2026-10-16","realtime_start":"2026-10-19","realtime_end":"9999-12-31","value":"3.750"}]}"#
            releases=[try release(.highYieldOAS,"2026-10-16","2026-10-16/2026-10-18","2026-10-16T21:00:00Z"),
                      try release(.highYieldOAS,"2026-10-16","2026-10-19/9999-12-31","2026-10-19T20:00:00Z")]
        case .cboeIndexHistoryCSV:
            series=[.vix]; population=nil; code=nil; scope=nil
            raw="DATE,OPEN,HIGH,LOW,CLOSE\r\n10/16/2026,20.00,22.00,18.00,19.00\r\n10/19/2026,19.00,21.00,17.00,18.00\r\n"
            releases=[try release(.vix,"2026-10-16",revision,"2026-10-16T21:00:00Z"),try release(.vix,"2026-10-19",revision,"2026-10-19T21:00:00Z")]
        case .cboePutCallHistoryCSV:
            series=[.equityPutCall]; population="CBOE:C1:EQUITY"; code=nil; scope=nil
            raw="DATE,CALL,PUT,TOTAL,P/C Ratio\n10/16/2026,100,75,175,0.75\n10/19/2026,100,80,180,0.80\n"
            releases=[try release(.equityPutCall,"2026-10-16",revision,"2026-10-16T21:00:00Z"),try release(.equityPutCall,"2026-10-19",revision,"2026-10-19T21:00:00Z")]
        case .cftcFinancialFuturesCSV:
            series=[.assetManagerNetOverOI,.leveragedFundsNetOverOI]; code="13874A"; scope = .futuresOnly
            // Contract market identifiers are six alphanumeric characters, not numbers.
            population="CFTC:TFF:13874A:futuresOnly"
            raw="Market_and_Exchange_Names,As_of_Date_In_Form_YYMMDD,Report_Date_as_MM_DD_YYYY,CFTC_Contract_Market_Code,Open_Interest_All,Asset_Mgr_Positions_Long_All,Asset_Mgr_Positions_Short_All,Lev_Money_Positions_Long_All,Lev_Money_Positions_Short_All,FutOnly_or_Combined\n\"SYNTHETIC INDEX, EXCHANGE\",261013,10/13/2026,13874A,1000,600,200,100,300,FutOnly\n"
            releases=try series.map { try release($0,"2026-10-13",revision,"2026-10-16T20:00:00Z") }
        }
        let descriptor=MacroSourceDescriptor(format:format,series:series,sourceID:"SYNTHETIC:"+format.rawValue,
            feedID:"SYNTHETIC:offline-v1",basisVersion:"SYNTHETIC:native-v1",population:population,revisionID:revision,
            sourceReference:"SYNTHETIC format fixture; not a downloaded source",licenseEvidence:"SYNTHETIC; no real provider authorization",
            cftcContractCode:code,cftcScope:scope)
        return .init(createdAt:now,retrievedAt:now,asOf:now,origin:.synthetic,descriptor:descriptor,rawData:Data(raw.utf8),releases:releases)
    }
    static func instant(_ text:String) throws -> Date {
        guard let date=ISO8601DateFormatter().date(from:text) else { throw MacroSourceError.invalidInput }; return date
    }
    static func release(_ series:MacroSeriesID,_ day:String,_ vintage:String,_ at:String)throws->MacroReleaseEvidence {
        let instant=try instant(at)
        return .init(series:series,observationDate:day,vintageID:vintage,releasedAt:instant,availableAt:instant,
                     evidenceReference:"SYNTHETIC explicit release fixture")
    }
}
