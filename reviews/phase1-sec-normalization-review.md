# Phase 1 SEC and financial normalization review

## Review scope

This change adds the first SEC EDGAR and financial normalization code slice. It is based on the merged Phase 1 calendar work and contains source, synthetic tests, traceability metadata, and this review note.

Reviewing or merging this change does not qualify a data supplier, enable production networking, finish the one-click research workflow, or close Phase 1/G1.

## SEC source boundary

- Adds closed operations for ticker/CIK identity, submissions, Company Facts, filing indexes, and filing documents.
- Builds only declared HTTPS SEC paths from validated CIK, accession, page, and file identifiers.
- Requires an identifying product/contact User-Agent and caps the supplied monotonic request limiter at 10 requests per second.
- Uses no API key. No SEC provider or URLSession transport is composed into the application, and production entitlements remain unchanged.
- Keeps HTTP errors, throttling, empty pages, partial pages, and malformed responses distinct.
- Preserves current and historical submissions page tokens, amendments, filing dates, accepted timestamps when supplied, and exact raw response bytes.

The request policy follows the SEC's public EDGAR API and fair-access documentation. Capability and entitlement snapshots still have to be supplied and accepted; code support is not evidence of rights or data qualification.

## Accepted ingest and history

Only the accepted-payload client can convert a provider response into the type consumed by SEC SQLite ingest. It binds the exact request, capability snapshot, entitlement, provider/feed, endpoint, page, raw bytes/hash, evidence, and license declaration before storage.

The `business.p1.v3` migration adds immutable issuer, listing, submission, filing index/document, Company Facts, dictionary, and normalization-result tables. Typed records and their raw source bytes commit atomically and are hash-checked on read.

Source versions are derived from each record's own source fields. A new request carrying identical content writes nothing and does not advance the store revision. If an aggregate response adds one fact, only that fact is added; unchanged facts do not become artificial revisions. SEC source bytes referenced by stored SEC records are protected from general cache purge.

## Financial normalization

- Adds an immutable exact taxonomy/concept/unit dictionary with an initial core US GAAP field set.
- Selects revisions by each version's availability evidence at the requested cutoff; it never substitutes current/latest facts.
- Preserves explicit zero, source spelling, units, periods, accession numbers, unmapped concepts, and dimension-bearing facts.
- Rejects ambiguous revisions and conflicting aliases instead of selecting an arbitrary value.
- Prefers reported discrete quarters, then derives only supported same-basis Q2/Q3/Q4 bridges.
- Computes TTM only from four contiguous additive quarters; instant, per-share, YTD, and incomplete windows are excluded.
- Carries source versions, derivation, confidence, and limitations into every result.
- Recomputes a normalization result from exact SQLite source facts before persisting it, preventing forged derived values.

## Verification

The fixed public catalog declares 163 Swift tests: 162 execute successfully and one real-Keychain test must remain `NOT_EXECUTED`; there are 30 suites. Thirteen new tests cover SEC identity, paging, amendments, facts, filings, request policy, failure handling, PIT selection, mapping, quarter/YTD/TTM rules, repeat retrievals, cache protection, and SQLite reopen/recalculation.

The clean public candidate passes the full repository verification under local Xcode 27 beta 6: the test catalog, 12 traceability checks, four UTC checks, module boundaries, Debug/Release builds, production sandbox checks, and Release isolation.

## Open boundaries

All provider responses in this review are synthetic fixtures shaped like the official endpoints. There is no live SEC request, downloaded filing, real entitlement decision, API credential, user data, or purchase.

Company Facts availability is day-level when the source supplies only a filing date. Filing indexes and documents become available at observed retrieval time; no earlier historical availability is invented.

The initial dictionary is a normalization foundation. It does not claim complete taxonomy coverage, core ratios, valuation, scoring, change summaries, ten-company golden acceptance, or research UI. Those remain in later Phase 1 work.

Private specifications, task maps, research notes, logs, and project memory are not part of this repository or review.
