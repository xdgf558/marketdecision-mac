# Public foundation source/test accounting

`source-tests.json` fixes the current public Swift source inventory and individual
Swift Testing selectors. Source associations are reviewed regression-suite groups,
not line coverage or proof that each behavior is tested. Module shells and native
app surfaces without automated behavioral tests are explicitly listed separately.
It contains no private specification/task/acceptance mapping.

Run `DEVELOPER_DIR=<selected Xcode>/Contents/Developer bash MarketDecision/Scripts/verify-ci.sh all`
from the clean public repository. The test step validates inventory and output
boundaries, runs the checker mutation tests, then creates a fresh Swift Testing
version-0 event stream. Missing/unknown tests, unexpected skips, issues, incomplete
runs and zero/incomplete parameter cases fail. The command exit status must also
succeed. This uses the event-stream flags supported by the selected Swift toolchains;
unknown formats fail and need an explicit compatibility review.

Only the existing optional Keychain test may be NOT EXECUTED. It must actually emit
a skip and is never included in passed counts. A successful test declaration without
start/end events cannot count as execution. Tests are not generated from this catalog;
new or renamed source/tests require a reviewed catalog change.

A successful report is written to `.build/validation/trace-report.json`, with the
individual executed/skipped selectors and SHA-256 of the verification inputs.
The previous report is removed before running; inputs must be unchanged through
completion. Raw events are temporary. CI uploads no report, log or artifact.
The report is execution accounting, not authentication or semantic/full acceptance.

Logging accepts only a closed event type, through the same renderer used by the
system sink and injected test sinks. Tests exercise credentials and error descriptions
containing synthetic sensitive material, ambiguous write/delete failures, rejection,
recovery and shared injection. The narrow source guard rejects common unreviewed output
APIs/raw error formatting, including ordinary/raw-string interpolation of `error`
and explicit catch aliases. It is lexical: assignment aliases and arbitrary Swift
expressions are not fully traced. It is not a Swift parser, full taint analysis or secret scanner.
The unchanged Debug-only diagnostic has a pinned source exception. The test-only
codec's fixture stdout is outside the application logging boundary.

Private requirements, full acceptance cases, target-device UI, signed Keychain,
real suppliers/backup recovery and performance need their own evidence. Public CI
success cannot close those gates or authorize the next phase.

Parameterized fixtures must provide distinct encodable arguments on both selected toolchains. Existing tuple fixtures use string arrays with unchanged values because Swift Testing 6.1 gives non-Encodable tuples the same unavailable case identity. The verifier continues to reject duplicate case identities.

The production `WorkspaceModel` is execution-tested through injected preparation,
quote providers and a shared event sink. Coverage includes failed/cancelled preparation,
provider failure after a previous success, retry, already-cancelled and overlapping
requests, and late responses from cancellation-ignoring dependencies. The local factory
is exercised with a temporary database and the synthetic provider, without Keychain
access. This does not automate native scene lifecycle, commands, sheets or actual
Unified Log collection; the app entry remains `build_only` for those surfaces.
Array-backed numeric fixtures assert their required lengths before indexing.

The separate `Scripts/verify-native-ui.sh` runs four XCTest UI cases in
`NativeUITests/NativeInteractionTests.swift`. The independently identified
MarketDecisionUITestHost compiles the same native views with a compile-time-only
factory using synthetic quotes, an in-memory database and an in-memory credential
presence store. Neither shipping configuration compiles that factory. UI tests
are separate from the 133 Swift Testing declarations; the xcresult summary and
individual case results must both report four passes with no skips. Unknown result
formats fail. A failed or unavailable runner is not a passed platform check.

Coverage is limited to explicit save vs text-field Return, enabled-state keyboard
paths, native replace/delete sheets, shared state in independent Settings, stale
sheet dismissal and failure/check/retry. Native scene wiring is exercised here;
the foundation catalog's `build_only` label remains specific to its Swift Testing
accounting. Neither XCTest nor accessibility labels establish full VoiceOver,
real input-method composition, visual/contrast compliance or signed Keychain
behavior. Local screenshots and the complete acceptance mapping remain private.

The isolated UI host receives Xcode-generated read-only-root and test-service
exceptions. Its separate exact permission/identity check runs before and after
native execution, with five rejection tests in addition to the seven result
checks. The production permission verifier is unchanged; XCTest automation does
not establish shipping-app sandbox behavior. Any added exception fails closed and
requires review; do not widen the checker merely to make a changed Xcode pass.

Native sheets are always queried through their owning window. The independent
Settings window is found by its stable credential controls and absence of the main
navigation, not a private SwiftUI window identifier; failures print a bounded window
inventory. The test directly requires the independent window to remain focused and
to own its confirmation after another page's older sheet is invalidated.
