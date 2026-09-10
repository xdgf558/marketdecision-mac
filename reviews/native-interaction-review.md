# Native interaction acceptance review

The credential input's Return action no longer submits a save. Text entry and
input-method candidate confirmation must not implicitly persist a credential;
the Save button and Command-S remain explicit entry points. Existing enabled-state
focus, confirmation IDs/revisions and Command-R/Command-D confirmation remain.
The accessibility hint describes this behavior, and controls have stable test IDs.

## Native execution scope

A separate MarketDecisionUITestHost target compiles the shared production views
with a compile-time-only factory, synthetic quotes, an in-memory database and an
in-memory credential presence store. It has a different bundle identifier and
never uses Keychain or retains credential bytes. Shipping Debug/Release do not
compile that factory; the Release product check rejects its diagnostic markers.
There is no shipping runtime flag to select this fixture.

The NativeInteractionTests scheme contains four XCTest UI cases:

| Case | Required observations |
| --- | --- |
| Return and keyboard | Text-field Return leaves an unsaved draft; explicit save works; disabled write controls are skipped |
| Native confirmation | Replace/delete sheets reject default Return, accept explicit keys, support cancel and restore input focus |
| Independent Settings | Shared state, older sheet dismissal after another page checks, current Settings command scope |
| Failure recovery | Injected failed save disables input until a successful check; an explicit fresh save may retry |

`Scripts/verify-native-ui.sh` requires an explicit DEVELOPER_DIR and, in hosted CI,
the actual OS major must be 15. It requires xcodebuild success plus xcresult aggregate
and individual case results: exactly four passes, no skips. Seven checker mutation
tests reject empty, missing, duplicated, failed or skipped results. Unknown result
schemas fail. An unsuccessful/unavailable runner is not runtime evidence.

The existing 133 Swift Testing declarations remain separate: 132 executed cases
and one required Keychain skip (NOT EXECUTED). Native UI cases are not added to
that count. Debug/Release, effective permissions and Release isolation stay checked.
No certificates, secrets, screenshots, xcresult bundles or other artifacts are uploaded.

## Limits and exit boundary

Synthetic-host UI execution does not establish signed Keychain, shipping-app
startup/storage integration, full VoiceOver speech/navigation, actual Chinese IME
composition, full visual/size/contrast coverage, Intel runtime or performance.
Local UI observations and complete evidence remain private. Return regression
tests are not proof of an actual input method's marked-text behavior.
The minimum deployment declaration is still macOS 15.0; a run on a newer 15.x patch
only proves that recorded environment. Keychain implementation, entitlements and
LICENSE are unchanged. Phase 0/G0, DATA-001, DATA-000 and G5 remain open; route B,
free-first, no procurement and no next-phase authorization remain unchanged.
