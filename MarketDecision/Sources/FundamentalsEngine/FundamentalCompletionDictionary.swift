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

    /// Separate evidence version. The four exact lease-liability components are not aliases
    /// for a total; SEC lease normalization may sum a complete, same-filing pair. Existing
    /// v1 rules and all formula definitions remain unchanged.
    /// Definitions retained in SEC taxonomy presentations (ASC 842-20-45-1(b)):
    /// https://www.sec.gov/Archives/edgar/data/1731289/000119312521166652/R66.htm
    /// https://www.sec.gov/Archives/edgar/data/1734107/000119312521084895/R99.htm
    /// LineOfCredit is the carrying amount of drawn long-term obligations, including both
    /// current and noncurrent portions. Retain it as a separate disclosure, never as either
    /// maturity bucket, the facility's borrowing limit or the complete debt total:
    /// https://www.sec.gov/Archives/edgar/data/1691421/000169142126000055/lmnd-20260630.htm
    public static func fundamentalsCompletionV2() throws -> Self {
        var rules = try fundamentalsCompletionV1().rules
        let additions = [
            ("FinanceLeaseLiabilityCurrent", "lease-components.finance-current"),
            ("FinanceLeaseLiabilityNoncurrent", "lease-components.finance-noncurrent"),
            ("OperatingLeaseLiabilityCurrent", "lease-components.operating-current"),
            ("OperatingLeaseLiabilityNoncurrent", "lease-components.operating-noncurrent"),
            ("LineOfCredit", "debt-disclosures.line-of-credit-total")
        ]
        for (concept, field) in additions {
            rules.append(try .init(taxonomy: "us-gaap", concept: concept, sourceUnit: "USD",
                                  fieldID: field, statement: .balanceSheet, nature: .instant))
        }
        return try Self(version: "financial-fields.us-gaap.completion.v2", rules: rules)
    }
}
