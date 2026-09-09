# Phase 0 native foundation

This is a local-first SwiftUI foundation demo, not a completed investment application. The macOS deployment target is 15.0. Development validation used Xcode 27 beta 6 (27A5252f), Swift 6.4, as explicitly selected for this iteration; that is not a release-toolchain qualification.

## Build and test

Open `App/MarketDecision.xcodeproj` and select the shared `MarketDecision` scheme. The development bundle identifier is the placeholder `local.marketdecision.development`.

From the repository root, set `DEVELOPER_DIR` to your installed Xcode's `Contents/Developer` directory, then run:

```sh
bash MarketDecision/Scripts/verify-local.sh
```

The script requires an explicit toolchain path, runs a structural boundary/pin check, the included Swift tests and an arm64 Debug build. It does not install tools, accept licenses or change global `xcode-select`. Initial dependency resolution needs network access. GRDB 7.11.1 is pinned to an exact revision in both resolution files.

## Implemented slice

- Native workspace and settings navigation, visibly synthetic DEMO quote, refresh, mock connection test and persistent appearance preference. UI remains iterative.
- Swift 6 package targets and dependency injection through AppEnvironment. Future analytics engines are empty boundaries.
- Quote-provider protocol, deterministic mock, basic provenance and four-axis data types. Real-data qualification, full timestamp/vintage/NBBO policies and provider families remain incomplete.
- Decimal-string amounts, posting rounding, equal allocation and encoding; full numeric/unit/division policy is not complete.
- Version-protected model registration, without the complete governance/result-envelope system.
- One SQLite/GRDB store with migration metadata and no business schema. No automatic erase on migration failure. Complete backup/restore is not implemented.
- Keychain wrapper and allowlisted log events. Logical Security compiles as SecuritySupport to avoid a collision with Apple's framework name.

## Evidence and known gaps

The local implementation was built for arm64 and cross-built for x86_64 in Debug. The arm64 app was launched and basic refresh/settings/light/dark interactions were inspected. Cross-compilation is not Intel runtime support, macOS 15 runtime verification, a universal-release promise or a performance result. Debug ad-hoc signing is not Developer ID/notarization or hardened-runtime qualification.

**19 regular test functions passed.** The additional opt-in Keychain integration test was actually attempted and failed with OSStatus **-34018** in the current test host. Its default state is skipped, which is not a pass. To attempt it in an appropriately signed/entitled host, run `MARKETDECISION_TEST_KEYCHAIN=1 xcrun swift test --package-path MarketDecision` with the chosen `DEVELOPER_DIR`. The test uses a unique disposable service and synthetic data, attempts cleanup, and never reads real credentials. No real-key input UI is offered yet.

These source-level synthetic tests are included and can be rerun. Full private acceptance cases, parameters, traceability records, device preflight and visual QA evidence are not included. The original 84 acceptance scenarios remain unexecuted as complete scenarios; the 57 earlier reference checks are not 57 production tests. Do not infer full coverage from this PR.

No hosted CI workflow has been created or run. The local script is not the Phase 0 CI exit criterion. Keychain entitlement evidence, complete foundation contracts, CI/traceability execution, minimum-system runtime, Intel runtime, full accessibility and Release performance remain open.

DATA-000 remains route B with G5 unpassed and no qualified supplier; no Bootstrap/calibration or real historical analysis is implemented here. Data remains free-first; no paid API or real market data is invoked. GPT is not used to fill missing market data. This slice does not start later analysis phases or close Phase 0.
