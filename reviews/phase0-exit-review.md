# Phase 0 exit candidate review

This batch closes two known foundation defects before the G0 decision. A provider
or preparation factory throwing `CancellationError` without cancelling the current
task is now reported as a failure; only cancellation of the refresh task produces a
cancelled result. The already-cancelled regression cancels inside its own task and no
longer depends on MainActor scheduling order.

An approved in-memory snapshot plan now survives one injected transient commit
failure while storage and revision remain unchanged. Retrying the same approval
commits the exact candidate once; a successful retry consumes it, and a stale
revision still requires a fresh prepare/approval cycle. This is a synthetic Phase 0
contract, not a durable business store or crash-recovery claim.

The synthetic workspace displays quote amounts through the calculation layer's
locale-independent fixed two-decimal policy. The four existing native UI cases also
pin the credential field's accessible name, the replacement panel's title/actions,
and the exact failed-save message. The production Keychain implementation,
entitlements, confirmation authorization rules and LICENSE are unchanged.

## Required evidence

The exact PR head must execute 133 required Swift tests and report the single real
Keychain integration case as `NOT EXECUTED`. It must also pass the existing four
native UI cases on hosted macOS 15 with no failure or skip, plus module, log,
Debug/Release, production entitlement, Release isolation and synthetic-host
permission checks. Declarations, prior runs and build-only results do not substitute
for execution at this head.

## G0 decision boundary

This PR is a candidate for the Phase 0 exit decision. Merging it does not itself
approve G0 or start Phase 1. The final approval remains a separate user decision
against the complete local acceptance record.

The local Product Design audit found usable accessibility names and native keyboard
behavior, but did not capture actual VoiceOver speech/cursor output or an observable
marked-text candidate window from the currently installed Chinese input method.
Those observations are not claimed as passed here. The proposed G0 decision keeps
full assistive-technology and input-method combinations in the release compatibility
matrix while accepting the tested semantic and macOS 15 interaction foundation.

Business schemas, ZIP restore, real providers and licensing, complete financial
models and scenarios, DATA-000/G5 qualification, Intel/universal release, performance,
Keychain lock/reboot/backup behavior and notarization remain in their owning phases.
Route B, free-first, no procurement and the rule that GPT must not supply market data
remain unchanged. Private specifications, task maps, screenshots, signing evidence
and project memory are not included.
