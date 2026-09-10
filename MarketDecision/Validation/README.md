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
APIs/raw error formatting; it is not a Swift parser, full taint analysis or secret scanner.
The unchanged Debug-only diagnostic has a pinned source exception. The test-only
codec's fixture stdout is outside the application logging boundary.

Private requirements, full acceptance cases, target-device UI, signed Keychain,
real suppliers/backup recovery and performance need their own evidence. Public CI
success cannot close those gates or authorize the next phase.

Parameterized fixtures must provide distinct encodable arguments on both selected toolchains. Existing tuple fixtures use string arrays with unchanged values because Swift Testing 6.1 gives non-Encodable tuples the same unavailable case identity. The verifier continues to reject duplicate case identities.
