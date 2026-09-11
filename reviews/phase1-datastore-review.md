# Phase 1 datastore review

Status: implementation candidate for review. This document does not approve a phase gate or complete the parent tasks.

## Scope

This change implements the first durable business-store slice for `P1-DATASTORE` (`DATA-005`, `DATA-010`, `PRJ-014`, and `PRJ-015`):

- a versioned GRDB migration for source documents, point-in-time observations, immutable snapshot objects, roots, and reference edges;
- atomic ingest of exact provider bytes and their normalized observations;
- point-in-time selection using each stored version's own availability evidence, with no fallback to the current/latest value;
- immutable research snapshot graphs that survive process restart and protect transitive references from cleanup;
- transactional restore/delete commits with persisted revision checks and retry after an injected transient failure;
- cache deletion that cannot remove the independently frozen bytes required by a research snapshot.

The application composition now opens this store beside the existing foundation database. A legacy foundation-only database is upgraded without erasing its existing rows.

## Data and integrity boundaries

Provider/feed/endpoint, evidence, license reference, availability, raw-object reference, and raw hash must agree before ingest. Source identity reuse with different bytes or metadata, and observation identity reuse with different canonical content, reject the whole transaction.

Exact numeric values remain decimal text in SQLite. Observation payloads use sorted JSON keys and the existing canonical millisecond UTC representation. Reads verify stored hashes and denormalized index columns before returning values.

Closed endpoint descriptors are now mapped to provider capabilities. A provider response whose endpoint does not match the dispatched capability is rejected before publication.

This slice contains no production adapter or production ingest call site. Direct calls to `BusinessDataStore.ingest` exist only in synthetic tests. The provider contract verifies endpoint/capability equality when accepting a response, while the store independently rechecks provider/feed/endpoint and source metadata coherence. The first real adapter pipeline must pass provider-result acceptance before constructing storage records; this review does not claim end-to-end adapter-to-store proof.

Frozen research objects own copied bytes in the snapshot tables and do not retain source-cache rows through a foreign key. Cache purge can therefore remove an unreferenced source document without changing frozen snapshot bytes. A workflow that must retain an original filing or PDF must freeze those source bytes into its research graph or prohibit their purge; that product policy is outside this slice.

Prepared restore/delete plans are process-local and expire on restart. The database and immutable graphs persist; an old approval is intentionally not treated as a durable authorization token. Snapshot graph rewrites currently use one database transaction and have not received scale or crash-injection performance qualification.

## Verification

The fixed public catalog contains 142 tests in 26 suites: 141 are required and executed, while the existing real Keychain integration test remains explicitly `NOT EXECUTED`. New cases cover restart persistence, idempotent replay, immutable conflicts, as-of availability, cache/snapshot separation, transitive protection, transient commit retry, stale-plan consumption, and upgrade from a foundation-only database.

Debug and Release application builds, module boundaries, production entitlements, and Release test-marker isolation are checked separately. No UI behavior or production entitlement is changed by this slice.

## Exclusions

All data used by these tests is synthetic. This change does not connect a live market, filing, or macro provider; qualify a vendor or license; download data; purchase a service; implement ZIP backup files; or execute financial models and the private acceptance-case set.

Merging this review would accept this code slice only. It would not close Phase 1 or G1, qualify `DATA-000`/G5, approve a supplier, or mark the multi-phase parent tasks complete. Full development specifications, task maps, evidence logs, and project memory remain local and are not part of this repository.
