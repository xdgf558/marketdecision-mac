# Security and traceability foundation review

Credential error paths previously had only two fixed-message logging assertions,
and CI did not reconcile a fixed source/test inventory with actual execution.
This change adds typed event logging at existing boundaries and fresh test accounting.

## Changes

- Logging accepts only closed events. Production and injected test sinks share a
  renderer; Error objects, credential bytes, URLs, headers and account references
  are not accepted by the API. Existing settings success/failure/rejection paths
  emit events without adding suspension points. Environment injection is shared.
- Six synthetic tests check output events, sensitive error descriptions, ambiguous
  post-write/post-delete failure, rejection, recheck recovery and multi-page injection.
  A failed operation does not claim success or retry without checking status again.
- A fixed public catalog distinguishes regression-associated source, build-only
  native surfaces and module shells. Individual test selectors are pinned; association
  by suite is not line coverage or proof of semantic completeness.
- CI requires a successful test command plus a fresh Swift Testing v0 event stream.
  Missing declarations/execution, issues, unexpected skips, incomplete runs and empty
  or incomplete parameterized cases fail. Unknown formats fail explicitly.
- Only the existing Keychain test may be NOT EXECUTED; its skip must be observed.
  Verification inputs are hashed before/after the run; stale reports are removed first.
  Reports stay in the ignored build folder, with no CI artifact upload.
- Ten Python checker tests exercise inventory, event and log-boundary rejection paths.
  Common direct logging/error formatting is rejected; the unchanged Debug diagnostic
  has a source-hash exception. This guard is not full taint analysis or a secret scanner.

## Evidence and count correction

The current test inventory is **125 declared functions: 124 executed successfully,
1 Keychain test skipped (NOT EXECUTED)**, plus 10 checker and 4 UTC Python tests.
Swift Testing's console total includes skipped tests. Earlier notes incorrectly called
those totals passing regular tests: PR23's 97 was 96 executed + 1 skipped; PR24's 119
was 118 executed + 1 skipped. Existing logs were re-counted; old commits were not rerun.
The new six-function increment is unchanged. This corrects accounting, not Keychain qualification.

The existing settings failure/recheck flow was observed locally with synthetic input:
failed save cleared the draft, showed uncertain status and kept Check available;
recheck restored absent status and focus. Layout and copy are unchanged. This does not
establish VoiceOver, IME, target macOS UI, Intel, lock/reboot/backup or performance acceptance.

Log tests inspect the same rendering boundary through a capture sink, not a live
Unified Log archive. Native startup/quote catch sites have source/build checks only.
Local validation uses the selected Xcode 27 beta 6; CI uses macOS 15/Xcode 16.4.
Hidden event-stream interface compatibility is verified per toolchain, not promised forever.

Private specifications, full traceability, task lists, audit screenshots and memory
remain local. LICENSE, entitlements, Keychain implementation and storage plans are unchanged.
Review/merge does not close Phase 0, DATA-001, DATA-000 or G5, approve the full acceptance
catalog, procure data, or start the next business phase.
