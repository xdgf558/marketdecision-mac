import Foundation
import CoreDomain
import DataContracts

public enum SECValuationError: Error, Equatable {
    case invalidEvidence, sourceMismatch, incompatibleAccounting, unsupportedFormat, unsupportedPrice
}

/// The caller supplies the immutable parent's original bytes. These bytes are not duplicated in
/// the report. Every open/save validates citations against the exact parent, not mutable caches.
public struct SECValuationSourceMaterial: Sendable, Codable, Equatable {
    public let reference, contentHash: String
    public let bytes: Data
    public init(reference: String, contentHash: String, bytes: Data) throws {
        self.reference = reference; self.contentHash = contentHash; self.bytes = bytes
        try validate()
    }
    public func validate() throws {
        guard valuationText(reference, 1_024), valuationHash(contentHash), !bytes.isEmpty,
              bytes.count <= 128 * 1_024 * 1_024, digest(bytes) == contentHash else { throw SECValuationError.sourceMismatch }
    }
}

/// Exact UTF-8 evidence excerpt. A valid byte binding proves what was cited, not whether the
/// user's interpretation of that text is correct. Byte offsets are never character offsets.
public struct SECValuationSourceAnchor: Sendable, Codable, Equatable {
    public let sourceReference, sourceHash: String
    public let byteOffset: Int
    public let excerpt: Data
    public init(sourceReference: String, sourceHash: String, byteOffset: Int, excerpt: Data) throws {
        self.sourceReference = sourceReference; self.sourceHash = sourceHash
        self.byteOffset = byteOffset; self.excerpt = excerpt; try validate()
    }
    public var text: String { String(decoding: excerpt, as: UTF8.self) }
    func validate() throws {
        guard valuationText(sourceReference, 1_024), valuationHash(sourceHash), byteOffset >= 0,
              !excerpt.isEmpty, excerpt.count <= 16_384, byteOffset <= 128 * 1_024 * 1_024 - excerpt.count,
              String(data: excerpt, encoding: .utf8) != nil, valuationText(text, 16_384)
        else { throw SECValuationError.invalidEvidence }
    }
    func validate(source: SECValuationSourceMaterial) throws {
        try validate()
        guard source.reference == sourceReference, source.contentHash == sourceHash,
              byteOffset <= source.bytes.count, excerpt.count <= source.bytes.count - byteOffset,
              source.bytes.subdata(in: byteOffset..<(byteOffset + excerpt.count)) == excerpt
        else { throw SECValuationError.sourceMismatch }
    }
}

public enum SECIndustryApplicability: String, Sendable, Codable, CaseIterable {
    case unknown, generalNonFinancial, financial, reit, specialized
}

/// An explicit, source-bound LOCAL interpretation. There is no automatic SIC allowlist and no
/// generic reviewed Boolean. It never certifies SEC industry classification or data eligibility.
public struct SECIndustryReview: Sendable, Codable {
    public let applicability: SECIndustryApplicability
    public let reviewedAt: Date
    public let rationale: String
    public let anchors: [SECValuationSourceAnchor]
    public init(applicability: SECIndustryApplicability, reviewedAt: Date, rationale: String,
                anchors: [SECValuationSourceAnchor]) throws {
        self.applicability = applicability; self.reviewedAt = reviewedAt; self.rationale = rationale
        self.anchors = anchors; try validate()
    }
    func validate() throws {
        guard reviewedAt.timeIntervalSince1970.isFinite, valuationText(rationale, 4_096),
              !anchors.isEmpty, anchors.count <= 16 else { throw SECValuationError.invalidEvidence }
        try anchors.forEach { try $0.validate() }
    }
}

/// The literal count excerpt must contain the exact unscaled integer. Class identity and the
/// meaning of the source count remain explicit human interpretation, disclosed in every report.
public struct SECReviewedShareClass: Sendable, Codable {
    public let classID, symbol: String
    public let outstandingShares: Money
    public let countAnchor: SECValuationSourceAnchor
    public let identityAnchors: [SECValuationSourceAnchor]
    public init(classID: String, symbol: String, outstandingShares: Money,
                countAnchor: SECValuationSourceAnchor, identityAnchors: [SECValuationSourceAnchor]) throws {
        self.classID = classID; self.symbol = symbol; self.outstandingShares = outstandingShares
        self.countAnchor = countAnchor; self.identityAnchors = identityAnchors; try validate()
    }
    func validate() throws {
        try EquityRecord.validateSymbol(symbol); try countAnchor.validate()
        guard valuationText(classID, 128), outstandingShares.amount > 0,
              !outstandingShares.decimalString.contains("."), !identityAnchors.isEmpty, identityAnchors.count <= 16,
              countAnchor.text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              try Money(countAnchor.text) == outstandingShares else { throw SECValuationError.invalidEvidence }
        try identityAnchors.forEach { try $0.validate() }
    }
}

/// A reviewed complete common-share universe for one issuer and one cover date. An observed
/// ticker list is not completeness evidence. This version makes no unlisted-class price proxy.
public struct SECShareClassReview: Sendable, Codable {
    public let cik: String
    public let coverDate: MarketDate
    public let accessionNumber: String
    public let classes: [SECReviewedShareClass]
    public let completenessAnchors: [SECValuationSourceAnchor]
    public let reviewedAt: Date
    public let rationale: String
    public init(cik: String, coverDate: MarketDate, accessionNumber: String, classes: [SECReviewedShareClass],
                completenessAnchors: [SECValuationSourceAnchor], reviewedAt: Date, rationale: String) throws {
        self.cik = cik; self.coverDate = coverDate; self.accessionNumber = accessionNumber; self.classes = classes
        self.completenessAnchors = completenessAnchors; self.reviewedAt = reviewedAt; self.rationale = rationale
        try validate()
    }
    func validate() throws {
        guard SECCompanyIdentityRecord.validCIK(cik), SECSubmissionRecord.validAccession(accessionNumber),
              (1...16).contains(classes.count), Set(classes.map(\.classID)).count == classes.count,
              Set(classes.map(\.symbol)).count == classes.count, !completenessAnchors.isEmpty,
              completenessAnchors.count <= 16, reviewedAt.timeIntervalSince1970.isFinite, valuationText(rationale, 4_096)
        else { throw SECValuationError.invalidEvidence }
        _ = try coverDate.start(in: TimeZone(secondsFromGMT: 0)!)
        try classes.forEach { try $0.validate() }; try completenessAnchors.forEach { try $0.validate() }
    }
}

/// This first policy ONLY accepts a reviewed common as-reported basis; it never applies a split
/// multiplier. Already-restated EPS cannot be adjusted twice. A required non-unit conversion must
/// remain unavailable until an independently versioned conversion policy is implemented.
public struct SECSplitBasisReview: Sendable, Codable {
    public let policy: String
    public let classIDs: [String]
    public let windowStart, basisDate: MarketDate
    public let coveredFactIDs: [String]
    public let anchors: [SECValuationSourceAnchor]
    public let reviewedAt: Date
    public let rationale: String
    public init(classIDs: [String], windowStart: MarketDate, basisDate: MarketDate, coveredFactIDs: [String],
                anchors: [SECValuationSourceAnchor], reviewedAt: Date, rationale: String) throws {
        policy = "as-reported-common-basis.no-conversion.v1"; self.classIDs = classIDs
        self.windowStart = windowStart; self.basisDate = basisDate; self.coveredFactIDs = coveredFactIDs
        self.anchors = anchors; self.reviewedAt = reviewedAt; self.rationale = rationale; try validate()
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case policy, classIDs, windowStart, basisDate, coveredFactIDs, anchors, reviewedAt, rationale
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: SECValuationEvidenceCodingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw SECValuationError.unsupportedFormat
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decode(String.self, forKey: .policy); classIDs = try c.decode([String].self, forKey: .classIDs)
        windowStart = try c.decode(MarketDate.self, forKey: .windowStart); basisDate = try c.decode(MarketDate.self, forKey: .basisDate)
        coveredFactIDs = try c.decode([String].self, forKey: .coveredFactIDs)
        anchors = try c.decode([SECValuationSourceAnchor].self, forKey: .anchors)
        reviewedAt = try c.decode(Date.self, forKey: .reviewedAt); rationale = try c.decode(String.self, forKey: .rationale)
        try validate()
    }
    func validate() throws {
        guard policy == "as-reported-common-basis.no-conversion.v1", !classIDs.isEmpty, classIDs.count <= 16,
              Set(classIDs).count == classIDs.count, classIDs.allSatisfy({ valuationText($0, 128) }),
              Set(coveredFactIDs).count == coveredFactIDs.count, coveredFactIDs.count <= 10_000,
              coveredFactIDs.allSatisfy({ valuationText($0, 1_024) }), windowStart <= basisDate,
              !anchors.isEmpty, anchors.count <= 32, reviewedAt.timeIntervalSince1970.isFinite,
              valuationText(rationale, 4_096) else { throw SECValuationError.invalidEvidence }
        _ = try windowStart.start(in: TimeZone(secondsFromGMT: 0)!)
        _ = try basisDate.start(in: TimeZone(secondsFromGMT: 0)!)
        try anchors.forEach { try $0.validate() }
    }
}

public struct SECValuationInputEvidence: Sendable, Codable {
    public let industryReview: SECIndustryReview?
    public let shareClasses: SECShareClassReview?
    public let splitBasis: SECSplitBasisReview?
    public let prices: [SECValuationPriceEvidence]
    public init(industryReview: SECIndustryReview? = nil, shareClasses: SECShareClassReview? = nil,
                splitBasis: SECSplitBasisReview? = nil, prices: [SECValuationPriceEvidence] = []) {
        self.industryReview = industryReview; self.shareClasses = shareClasses
        self.splitBasis = splitBasis; self.prices = prices
    }
    var anchors: [SECValuationSourceAnchor] {
        (industryReview?.anchors ?? []) + (shareClasses?.completenessAnchors ?? [])
            + (shareClasses?.classes.flatMap { [$0.countAnchor] + $0.identityAnchors } ?? []) + (splitBasis?.anchors ?? [])
    }
    func validate(accounting: SECFinancialReport, executionDate: Date) throws {
        try industryReview?.validate(); try shareClasses?.validate(); try splitBasis?.validate()
        let times = [industryReview?.reviewedAt, shareClasses?.reviewedAt, splitBasis?.reviewedAt].compactMap { $0 }
        guard times.allSatisfy({ accounting.cutoff <= $0 && $0 <= executionDate }), prices.count <= 16,
              Set(prices.map(\.classID)).count == prices.count else { throw SECValuationError.invalidEvidence }
        if let shares = shareClasses {
            guard shares.cik == accounting.evidence.cik,
                  shares.coverDate <= (try MarketDate(iso8601: valuationDay(executionDate))),
                  accounting.evidence.submissions.contains(where: { $0.accessionNumber == shares.accessionNumber
                    && ["10-K", "10-K/A", "10-Q", "10-Q/A"].contains($0.form) })
            else { throw SECValuationError.invalidEvidence }
        }
        if let split = splitBasis {
            guard let shares = shareClasses, Set(split.classIDs) == Set(shares.classes.map(\.classID)),
                  split.windowStart <= accounting.evidence.quarters[0].start,
                  split.basisDate >= shares.coverDate, split.basisDate >= accounting.evidence.quarters.last!.end,
                  split.basisDate <= (try MarketDate(iso8601: valuationDay(executionDate)))
            else { throw SECValuationError.invalidEvidence }
            let ids = Set(accounting.inputSnapshot.financials.input.normalization.values.filter {
                $0.unit == "USD/shares" || $0.unit == "shares"
            }.flatMap(\.sourceFactIDs))
            guard Set(split.coveredFactIDs) == ids else { throw SECValuationError.invalidEvidence }
        }
        for price in prices { try price.validate(executionDate: executionDate) }
    }
    public func validateSources(_ sources: [SECValuationSourceMaterial]) throws {
        guard sources.count <= 40, Set(sources.map(\.reference)).count == sources.count else { throw SECValuationError.sourceMismatch }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.reference, $0) })
        // Hash only cited source material here; the parent validates every original source itself.
        for reference in Set(anchors.map(\.sourceReference)) {
            guard let source = byID[reference] else { throw SECValuationError.sourceMismatch }
            try source.validate()
        }
        for anchor in anchors {
            guard let source = byID[anchor.sourceReference] else { throw SECValuationError.sourceMismatch }
            try anchor.validate(source: source)
        }
    }
}

func valuationText(_ value: String, _ maximum: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) }
}
func valuationHash(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
func valuationDay(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = TimeZone(secondsFromGMT: 0)!
    return formatter.string(from: date)
}

private struct SECValuationEvidenceCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
