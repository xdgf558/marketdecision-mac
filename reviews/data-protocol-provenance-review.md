# Data protocol and provenance foundation review

This batch adds the shared data boundary for later provider implementations.
It groups protocols, provenance, request validation and their synthetic regressions in one review.

## Implemented scope

- Typed protocols cover market data, fundamentals, macro series, ledger valuation and broker import preview/commit.
- Business payloads remain associated types owned by their later phases. Only the synthetic quote provider is implemented; unsupported mock capabilities fail explicitly.
- Requests bind provider, feed, resource, capability, mode/cutoff/range, usage, configuration and entitlement versions, request ID and page token.
- Capability support and supplied rights evidence are checked separately before dispatch. Responses must match the exact request and retain item-level provenance and license references.
- Complete, partial, empty and error results are distinct. Missing items, pagination and truncation prevent a complete result. COMPLETE describes the declared request/page scope, not a verified universe.
- The market client checks cancellation before dispatch and after return; there is no implicit retry or feed fallback. Cancellation discards a late response; it does not promise remote cancellation.
- Provenance records source/receive/request times, observation and version identity, availability evidence, raw-object/hash references, normalization and license references. Endpoint descriptors reject URLs and query strings.
- AS_OF selects a source version using its own availability evidence. Date-only releases use the next local calendar day, including DST; unknown timezone/version evidence cannot fall back to current values or legacy timestamps.
- Origin, timeliness, quality and usage remain separate. Legacy display labels confer no eligibility. Real-time quotes require supplied rights and freshness checks; delayed, stale, indicative and synthetic quotes are refused.
- Derived assessments consume required dependencies. Comparison-only data remains auditable, and excluded optional inputs require a reason and policy reference. Assessments remain bound to their evaluation time and usage.
- Numeric observations distinguish zero from missing/invalid, preserve raw decimal text and units, and require formula/model/parameter/input-version references for available derived values. They execute no financial model.
- Option-chain structure embeds the underlying quote and per-contract provenance. Request-cycle and skew checks do not establish price quality, feed rights or pricing eligibility; missing required times remain unknown.
- Import preview tokens bind a source hash and base revision. The protocol does not implement file parsing, one-time consumption, transactional commit or database recovery.

## Validation

The public source tests cover vintage selection, date/DST boundaries, interval bounds, invalid metadata,
rights and capability separation, request/feed/resource/license mismatches, paging and empty/error states,
quality inheritance, numeric provenance, chain timestamp skew, preview identity and late cancellation.

The suite contains 66 regular Swift tests, including 27 new data-foundation tests.
One optional real Keychain integration test remains skipped: NOT EXECUTED, not a pass.
Reproduction: select an installed Xcode with DEVELOPER_DIR and run `bash MarketDecision/Scripts/verify-ci.sh all`
from this clean public checkout. This also runs four UTC tests, module-boundary checks, arm64 Debug/Release
builds, effective-entitlement checks and the existing heuristic Release-marker check.

Local validation uses the user-selected Xcode 27 beta 6. Hosted CI uses its existing macOS 15 / Xcode 16.4
configuration; a successful build is not actual provider, UI, Intel or performance acceptance.

## Boundaries

Supplied capability/rights records are configuration evidence, not authenticated vendor qualification.
Reference/hash presence checks do not prove raw-object existence, correct normalization, source truth or permission.
The generic protocols are not full bar/option/filing/ledger schemas; specialized validation and production
adapters belong to their owning phases. Quote eligibility currently implements live-analysis checks only.

No supplier, network transport, paid API, import writes or financial engine is added. Existing DEMO remains
synthetic and unusable for analysis. UI, Keychain implementation, entitlements, CI permissions and LICENSE are unchanged.
DATA-000 remains route B with G5 not passed; free-first remains in effect and GPT is not a substitute for market data.
This batch does not execute all 84 private acceptance scenarios or close Phase 0, DATA-001 or existing platform/UI gaps.
Private specifications, task maps, parameters, memory and evidence remain local. Merge requires user review.
