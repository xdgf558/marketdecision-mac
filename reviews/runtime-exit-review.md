# Workspace runtime and foundation exit evidence review

This batch completes the application runtime logging follow-up and records a
limited current-machine regression. It does not approve Phase 0 exit.

## Runtime behavior

- The production WorkspaceModel now lives in AppComposition. Preparation, quotes
  and credential settings share one injected closed-event log; native AppKit
  sheet/command/rendering code remains at the app entry.
- Preparation failure/cancellation publishes neither environment nor credentials.
  Provider failure/cancellation clears the previous quote and emits fixed messages.
  Cancellation-ignoring late results cannot become successful refreshes.
- Overlapping refreshes return false without extra work. The Settings connection
  result uses this invocation's outcome, never an old quote's presence.
- Preparation cancellation prevents publication, not rollback of filesystem work
  already in progress. No business schema, provider, network or credential access
  is added to preparation.
- Eight runtime tests exercise the production model, shared sink and temporary
  local factory with synthetic dependencies. Errors containing synthetic sensitive
  text are not formatted. Native scenes/sheets and OS log collection are not automated.
- The lexical output guard rejects error interpolation and explicit catch aliases;
  it is not full Swift parsing or taint analysis. Numeric array fixtures now require
  their expected lengths before indexing.

## Verification scope

The public entry point is `MarketDecision/Scripts/verify-ci.sh all` with an explicit
DEVELOPER_DIR. It accounts for 133 Swift test declarations: 132 executed tests and
one required Keychain skip, reported as NOT EXECUTED. The checker has 12 mutation
tests; four UTC tests, module boundaries, Debug/Release builds and effective
entitlement/Release-isolation checks remain part of this entry point.

Separate private observations on the current Apple-silicon Mac with the authorized
beta toolchain cover signed Debug/Release launch, synthetic application-process
Keychain create/update/protection/read/delete/next-launch absence, and settings
save/replace/delete, cancel/success focus, Return rejection and explicit confirmation.
Light/dark and independent Settings were checked at the observed window sizes.
The synthetic credential was removed and absence verified after restart.
Intel cross-compilation succeeded; Intel runtime is not established. Local signing,
screenshots and UI observations are not reproduced by public hosted CI.

## Exit boundary

Full VoiceOver/IME, target macOS 15 native UI, lock/reboot/backup and performance
evidence remain open. Private exit accounting separates Phase 0 foundation evidence
from later real backup, business schema, model and supplier validation; it does not
waive missing basic UI/platform evidence or mark cross-phase parents complete.
DATA-000 remains route B/free-first, with no qualified supplier or G5 pass; its full
conclusion is not required for Phase 0. No purchase or next-phase work is authorized
by this PR. Private specifications, task/acceptance maps and evidence remain local.
