import Foundation
import DataContracts

extension FinancialFieldDictionary {
    /// Additive version: the existing dictionary remains immutable. These exact dimensionless
    /// mappings use FASB 2025 definitions; they are not issuer/industry taxonomy acceptance.
    /// https://xbrl.fasb.org/us-gaap/2025/elts/us-gaap-doc-2025.xml
    /// Debt coverage, common equity, cash issuance and split-adjusted shares require separate
    /// issuer evidence and are deliberately not guessed from superficially similar aggregate tags.
    public static func fundamentalsV1() throws -> Self {
        var rules = try foundationV1().rules
        let extra: [(String,FundamentalField,FinancialStatement,FinancialMetricNature,String)] = [
            ("GrossProfit",.grossProfit,.incomeStatement,.additiveFlow,"USD"),
            ("OperatingIncomeLoss",.operatingIncome,.incomeStatement,.additiveFlow,"USD"),
            ("NetIncomeLossAvailableToCommonStockholdersBasic",.commonIncome,.incomeStatement,.additiveFlow,"USD"),
            ("InterestExpense",.interest,.incomeStatement,.additiveFlow,"USD"),
            ("AssetsCurrent",.currentAssets,.balanceSheet,.instant,"USD"),
            ("LiabilitiesCurrent",.currentLiabilities,.balanceSheet,.instant,"USD"),
            ("CashAndCashEquivalentsAtCarryingValue",.cash,.balanceSheet,.instant,"USD"),
            ("StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest",.totalEquity,.balanceSheet,.instant,"USD"),
            ("ShareBasedCompensation",.sbc,.cashFlow,.additiveFlow,"USD"),
            ("PaymentsForRepurchaseOfCommonStock",.buybacks,.cashFlow,.additiveFlow,"USD"),
            ("PaymentsOfDividendsCommonStock",.dividends,.cashFlow,.additiveFlow,"USD"),
            ("OperatingLeaseWeightedAverageDiscountRatePercent",.leaseRate,.other,.instant,"pure")
        ]
        for (concept,field,statement,nature,unit) in extra {
            rules.append(try .init(taxonomy:"us-gaap",concept:concept,sourceUnit:unit,fieldID:field.rawValue,statement:statement,nature:nature))
        }
        return try Self(version:"financial-fields.us-gaap.fundamentals.v1",rules:rules)
    }
}
