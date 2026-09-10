# Data contract closure review

This batch addresses the five non-blocking contract findings from PR #21 together.
It changes foundation validation and synthetic tests; no real adapter or transport is added.

## Contract changes

- `configurationVersion` identifies the capability/configuration snapshot version and must equal
  `CapabilitySnapshot.version` before dispatch. Entitlement version binding remains separate.
  The mock now takes its request version from that snapshot. Version labels are not content authentication.
- Endpoint provenance accepts only the closed `EndpointDescriptor` logical-operation catalog.
  URLs, userinfo, query strings, bearer-like values, arbitrary paths and unknown identifiers are rejected,
  including after decoding. Concrete service endpoints belong in the versioned adapter configuration.
  This is not a general secret scanner for other string fields or a real adapter configuration implementation.
- An option chain's underlying quote must match its provider, feed and request cycle. Equal timestamps
  cannot authorize a different feed. The market client's chain return path exercises the same validation.
- `range` is now an explicit, inclusive `DataWindow`: source-event instants for quote/bars/chain,
  expiration-list snapshots, identity/submissions and ledger marks; calendar observation dates for
  company facts and macro series. Requests reject the wrong axis, and every returned item must be in range.
  AS_OF additionally requires the source version's availability at or before the cutoff. An event window
  must end at or before that cutoff; a past window need not contain the later cutoff. For example, a March
  observation can be queried with information available in May. Calendar days are not converted into UTC
  release instants or compared to an instant without source-timezone evidence. These generic checks do not
  establish business-specific observation/period validity, calendar completeness or source truth.
- `NumericObservation` supports identity normalization only in this foundation: source raw decimal text
  and the consumable value have the same unit/currency and must be numerically equal (`1.00` equals `1`).
  Available source observations require raw text; changing `4` into `0.04` is rejected. Original documents
  remain referenced by provenance. Unit/scale conversion needs an explicit future transformation contract.
  Derived observations may omit raw text because they carry calculation/input references; if supplied,
  that text must still equal the result. Invalid source text may remain auditable with no consumable value.

## Validation

The suite now has 75 regular Swift tests, including nine new regression tests. They cover pre-dispatch
version rejection with zero calls, decoded endpoint rejection, same-cycle cross-feed chain rejection
through both the contract and client, event/date window boundaries and wrong-axis rejection, serialization,
late vintage availability, and exact raw/value identity including zero, missing raw text and derived values.
The optional real Keychain test remains skipped: NOT EXECUTED, not a pass.

The clean public candidate is reproducible with an explicitly selected `DEVELOPER_DIR` and
`bash MarketDecision/Scripts/verify-ci.sh all`: Swift tests, four UTC tests, module boundaries,
arm64 Debug/Release builds, effective-entitlement checks and the existing heuristic Release-marker scan.
Local validation uses the user-selected Xcode 27 beta 6; hosted CI retains macOS 15 / Xcode 16.4.
CI result and exact commit must be checked on the PR. No UI, real supplier, Intel or performance acceptance is claimed.

## Compatibility and scope

The request range's tagged representation replaces the old untyped instant range. Old unregistered endpoint
strings no longer validate. This is a pre-adapter contract update, not a database migration or an automatic
reinterpretation of previously serialized requests. Existing DEMO remains synthetic and ineligible.

Quote construction still defers provenance validation to consumption boundaries, HTTP 404 remains a
conservative malformed response, and quote eligibility remains live-analysis-only. Derived assessments
still depend on upstream usage/rights evaluation. No UI, Keychain implementation, permissions, LICENSE,
CI workflow, financial engine or supplier qualification changes are included.

Private specifications, task maps, parameters, memory and evidence remain local. The PR does not approve
all DC fields or close Phase 0, DATA-001, DATA-000 or G5. Route B/free-first remain unchanged; GPT does not
replace market data. No purchase or next-phase work is started. Merge awaits user review.
