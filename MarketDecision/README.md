# Native foundation and Phase 1 data slices

MarketDecision is a local-first macOS SwiftUI application. The deployment target is macOS 15.0. Phase 0 has been approved; Phase 1 and its exit gate remain open. The running application still shows a synthetic DEMO quote and settings, with no real market provider or financial-analysis workflow connected.

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
- SQLite source bytes, typed records, immutable research snapshots, transactional migrations and local restore/deletion plans. This is not a ZIP backup or crash/performance qualification.
- Candidate calendar/events and SEC adapters, core financial normalization, and a candidate stock quote/daily-bar adapter. Adapters are exercised with synthetic HTTP responses and are not installed in the application startup path.

The IEX stock slice explicitly requests USD, raw daily bars, a single exchange and no automatic symbol-history mapping. Quotes retain timestamp/quality; stale or invalid quotes are not upgraded. Daily aggregates are not official settlement marks, adjusted return series or historical fills. Historical retrieval does not provide source-vintage PIT evidence. Pagination means one page, not a complete calendar window. Credentials are injected into HTTP headers by an explicitly constructed adapter; this batch neither requests real credentials nor changes Keychain or production entitlements. See [stock-slice review](../reviews/phase1-equity-review.md).

## Evidence boundaries

The fixed catalog records actual executions and the separately skipped real Keychain test. A skip is **NOT EXECUTED**, never a pass. Synthetic provider and SQLite tests do not qualify a vendor, feed, license, model or financial result. Original complete acceptance scenarios, real-source samples and private evidence are not published here.

The demo's production permissions remain sandbox-only; no network-client or user-selected-file entitlement is added. Optional account-signed Keychain checks are described in [KeychainHost](Tests/KeychainHost/README.md). Complete accessibility/IME, real Keychain lifecycle, Intel runtime, performance and notarized distribution remain tracked limitations. Ad-hoc Debug/Release builds and synthetic UI hosts do not close them.

Data is free-first. Route B is selected, G5 remains open and no supplier is qualified. GPT does not supply missing market data. Before a live adapter is composed, account/license evidence, redirects/cookies/caching, credential handling and production permissions require their own review. No paid API, purchase, trading or real network data collection is part of this slice.

All rights to original project code remain reserved; dependency licenses are documented separately.
