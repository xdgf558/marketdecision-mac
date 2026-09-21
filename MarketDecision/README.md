# Native foundation and Phase 1 data slices

MarketDecision is a local-first macOS SwiftUI application. The deployment target is macOS 15.0. Phase 0 has been approved; Phase 1 and its exit gate remain open. The running application still shows a synthetic DEMO quote and settings, with no real market provider or real-data financial-analysis workflow connected.

## Build and test

Open `App/MarketDecision.xcodeproj` and select `MarketDecision`. Select an installed Xcode explicitly for validation:

```sh
DEVELOPER_DIR=<selected Xcode>/Contents/Developer bash MarketDecision/Scripts/verify-ci.sh all
```

Run this from the clean public repository. It checks the tracked-file boundary, module boundaries, UTC/traceability checks, the fixed Swift test catalog, Debug/Release builds, effective demo permissions and Release diagnostic isolation. Initial resolution requires network access to the pinned GRDB 7.11.1 dependency. It does not install tools or change global xcode-select. Local development uses the user-selected Xcode 27 beta 6; hosted CI uses its separately declared toolchain. CI status must be checked for the exact commit.

The optional native interaction check is `bash MarketDecision/Scripts/verify-native-ui.sh` with the same explicit `DEVELOPER_DIR`. It uses a separate synthetic in-memory host and is not production Keychain or sandbox evidence. See [CI scope](Scripts/CI.md) and [test accounting](Validation/README.md).

## Current implementation

- SwiftUI DEMO workspace and credential settings, version-bound confirmations, closed security events and injected runtime dependencies.
- Exact decimal arithmetic, immutable model/parameter references, provenance, capability/rights/request acceptance and explicit PIT availability rules.
- SQLite source bytes, typed records, immutable research snapshots, transactional migrations and local restore/deletion plans. Research backups use the bounded ZIP profile described below; this is not crash/performance qualification.
- Candidate calendar/events and SEC adapters, core financial normalization, and a candidate stock quote/daily-bar adapter. Adapters are exercised with synthetic HTTP responses and are not installed in the application startup path.

The IEX stock slice explicitly requests USD, raw daily bars, a single exchange and no automatic symbol-history mapping. Quotes retain timestamp/quality; stale or invalid quotes are not upgraded. Daily aggregates are not official settlement marks, adjusted return series or historical fills. Historical retrieval does not provide source-vintage PIT evidence. Pagination means one page, not a complete calendar window. Credentials are injected into HTTP headers by an explicitly constructed adapter; this batch neither requests real credentials nor changes Keychain or production entitlements. See [stock-slice review](../reviews/phase1-equity-review.md).

## Evidence boundaries

The fixed catalog records actual executions and the separately skipped real Keychain test. A skip is **NOT EXECUTED**, never a pass. Synthetic provider and SQLite tests do not qualify a vendor, feed, license, model or financial result. Original complete acceptance scenarios, real-source samples and private evidence are not published here.

The demo's production permissions remain sandbox-only; no network-client or user-selected-file entitlement is added. Optional account-signed Keychain checks are described in [KeychainHost](Tests/KeychainHost/README.md). Complete accessibility/IME, real Keychain lifecycle, Intel runtime, performance and notarized distribution remain tracked limitations. Ad-hoc Debug/Release builds and synthetic UI hosts do not close them.

Data is free-first. Route B is selected, G5 remains open and no supplier is qualified. GPT does not supply missing market data. Before a live adapter is composed, account/license evidence, redirects/cookies/caching, credential handling and production permissions require their own review. No paid API, purchase, trading or real network data collection is part of this slice.

All rights to original project code remain reserved; dependency licenses are documented separately.

## Local research export and recovery candidate

The research Backup tab exports Markdown and a non-encrypted ZIP containing only frozen **synthetic** research, user watchlist targets/notes and preserved conflict copies. Markdown includes missing states, exact input/source bytes and model references, and is not a restorable backup. ZIP contains exactly `manifest.json` and `research-state.json`, with version, counts, SHA-256 and ordinary ZIP CRC-32. This is a ZIP32 stored-entry profile following [PKWARE APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT), not a general ZIP importer: deflate, ZIP64, encryption, extra entries, links and undeclared paths are refused. It never extracts archive paths to disk. Limits are 2 GiB archive, 1 GiB per entry and 100,000 combined business records; with two stored entries there is no compression expansion. These caps are safety limits, not validated device capacity.

Restore first validates version/hash, the complete reference graph, frozen sources/model context and offline recomputation. It then previews an exact process-local plan. Merge retains conflicting graph versions under new namespaces without rewriting frozen bytes; existing watchlist values remain primary and differing incoming values are retained as conflict copies. Repeated merge deduplicates the same graph and conflict content. Restored editable entries receive fresh revisions so old drafts cannot become valid again. Conflict copies retain their original revision for inspection and rebackup.

Replace affects only research, watchlist and conflict collections; source caches stay in place. The separately confirmed Clear Business operation removes all current business collections and source caches. Both operations check the current persisted revision inside one SQLite transaction. Cancelled, stale or failed operations do not partially write; a transient failure retains its plan for retry, while process restart invalidates all pending plans. Keychain is never read/imported/deleted by this subsystem. External backups remain untouched; deletion is logical and does not promise physical disk erasure. Source cache files, settings, future ledgers and real-provider evidence are not in this v1 backup scope.

The new seventh native case covers preview/cancel and explicit clear in the isolated in-memory host. Model tests and host compilation do not prove native execution or production file-panel access. File-picker entitlement authorization and actual file-panel/target-platform checks must be recorded separately before calling the end-to-end workflow accepted.
