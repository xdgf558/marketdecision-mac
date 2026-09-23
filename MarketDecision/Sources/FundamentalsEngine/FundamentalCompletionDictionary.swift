import Foundation

extension FinancialFieldDictionary {
    /// A new immutable dictionary, not an update of either existing version. These mappings
    /// follow the FASB 2025 definitions at the URL below. They do not qualify an issuer or feed.
    /// https://xbrl.fasb.org/us-gaap/2025/elts/us-gaap-doc-2025.xml
    /// Only exact, dimensionless concepts are accepted; mixed debt/lease aggregates, partial
    /// stock-plan proceeds and net-of-acquired-cash acquisition payments remain unmapped.
    public static func fundamentalsCompletionV1() throws -> Self {
        var rules = try fundamentalsV1().rules
        let additions: [(String, String, FinancialStatement, FinancialMetricNature)] = [
            ("IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest", "income.pretax-income", .incomeStatement, .additiveFlow),
            ("IncomeTaxExpenseBenefit", "income.tax", .incomeStatement, .additiveFlow),
            ("DepreciationDepletionAndAmortization", "cash-flow.depreciation", .cashFlow, .additiveFlow),
            ("ShortTermBorrowings", "debt.short-borrowings", .balanceSheet, .instant),
            ("LongTermDebtCurrent", "debt.current-excluding-leases", .balanceSheet, .instant),
            ("LongTermDebtNoncurrent", "debt.noncurrent-excluding-leases", .balanceSheet, .instant),
            ("FinanceLeaseLiability", "debt.finance-lease-total", .balanceSheet, .instant),
            ("OperatingLeaseLiability", "debt.operating-lease-total", .balanceSheet, .instant),
            ("PaymentsToAcquireBusinessesGross", "cash-flow.acquisitions-cash-paid", .cashFlow, .additiveFlow)
        ]
        for (concept, field, statement, nature) in additions {
            rules.append(try .init(taxonomy: "us-gaap", concept: concept, sourceUnit: "USD",
                fieldID: field, statement: statement, nature: nature))
        }
        return try Self(version: "financial-fields.us-gaap.completion.v1", rules: rules)
    }
}
