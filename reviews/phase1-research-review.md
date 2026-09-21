# Phase 1 local research workflow candidate

This slice connects the existing calculation kernel to a native research page, source inspector, watchlist and immutable research snapshots. App data remains explicitly synthetic. It does not admit a provider or connect production networking.

- DEMO and GAP exercise computed and missing states through the actual normalization/calculation code. Other watchlist symbols have no research data; synthetic values are never substituted for them.
- Research views distinguish TTM metrics, coverage scores, unavailable historical ranges and user-entered USD targets. Field inspection retains exact generated source text, periods, source revisions, availability and model/parameter references. Generated evidence is not an SEC filing.
- Saved runs freeze six hash-bound objects under a research root: complete document/input/results, financial source bytes, capital source bytes, model, parameters and mapping. All objects enter the existing SQLite graph transaction together. Reopening validates hashes, normalization and replay from saved inputs; it never regenerates a fixture in place of a saved run.
- Source-cache cleanup cannot remove these separate frozen bytes. Existing reference protection applies. Duplicate runs cannot overwrite the saved version. New runs use new identities. Address resolution follows restored graph mappings.
- Migration business.p1.v5 adds watchlist storage without erasing previous rows. Exact decimal targets and independent row revisions are validated on reads and writes. Removing a watchlist entry retains research snapshots. Risk notes are user annotations, not enforced system risk limits.
- Cancelled late computations do not publish. A committed save followed by a failed list refresh is reported as saved with a refresh failure, not rollback.

Validation: 16 new Swift regressions cover replay, missing states, reopening, source retention, transactional failure/retry, corruption, immutability, migration, watchlist concurrency and model failures. Final clean-copy verification: 238 Swift tests executed, one real Keychain test NOT EXECUTED (239 declarations, 40 suites); 12 traceability and four UTC checks, Debug/Release builds, effective permissions and Release isolation passed locally on macOS 27 / Xcode 27 beta 6 / arm64.

Native UI has two new tests plus four retained credential tests, with exact six-pass accounting. Local test-host build succeeded, but execution was blocked by macOS authentication before any test ran. Research-page visual verification was also blocked by the computer-use connection failing. These checks are pending, not passes; hosted macOS 15 evidence must be obtained on this candidate.

Private specifications, memory, screenshots and evidence remain local. No Keychain implementation, production entitlements or LICENSE change. Real company fixtures, source/provider admission, model calibration, full event/card coverage, production integration, user-facing export/restore and platform/performance acceptance remain open. This candidate does not close Phase 1/G1, DATA-000/G5 or parent tasks.
