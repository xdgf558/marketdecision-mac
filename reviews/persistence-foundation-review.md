# Persistence foundation review

This change completes a Phase 0 foundation slice for migration, immutable content,
reference protection, restore planning and business deletion. Cross-phase parent
work remains open. It introduces no business tables, supplier adapter, financial
engine, backup UI or file extraction/deletion tool.

## Behavior

- Model lifecycle timestamps use an integer-millisecond value with canonical UTC
  ISO-8601 encoding. Model references declare `model.v2.utc-ms`; legacy numeric
  dates and references without a format version are rejected, never silently upgraded.
  Registry fingerprints remain their own length-prefixed format, distinct from snapshot JSON.
- Frozen content contains ordered, hash-bound references and retention declarations.
  The restricted canonical JSON profile preserves Unicode, sorts object keys by
  UTF-16, and encodes Decimal/integer values as strings. Its Codable carrier is
  separate from canonical content; it is not a general JSON-number parser.
- Bundles require actual referenced content, matching hashes, supported versions,
  an acyclic graph and declared retention permission. Declarations are not license verification.
- SQLite migrations reject unknown/non-prefix history. Each migration is transactional;
  failed statements roll back while earlier successful migrations remain committed.
  There is no erase-on-change fallback or implicit business schema.
- The synthetic-only, in-memory store protects transitive references, freezes content
  without overwriting versions, and rejects cleanup when surviving content still needs it.
- Restore first validates and retains a plan tied to the current revision. Conflicts
  retain both copies through an external import mapping, leaving frozen bytes unchanged.
  Repeated identical imports reuse content, including previously remapped copies.
- Plans expose affected addresses and counts. Confirmation binds an exact retained
  plan/digest; stale, cancelled, reused or failed plans cannot partially change the store.
  The approval value is a workflow contract, not an authentication token.
- Cache cleanup, root deletion and business clearing are separate operations. The mock
  has no credential-store capability and reports credentials untouched.

## Verification and limits

The public tests add 22 cases to the previous 97: canonical content, dependency
protection, conflict/repeated restore, cancellation/stale plans/failure atomicity,
archive declarations and real temporary-SQLite rollback. A test-only executable
checks fractional model timestamps and exact references across three independent
processes; it is not linked into the app. The normal Keychain test remains skipped,
**NOT EXECUTED**, and is not included in the 119 passing regular tests.

Archive checks cover declared paths/types/sizes/hashes and staged canonical object
bytes. They do not implement ZIP parsing, physical compression/manifest accounting,
secure extraction or arbitrary-payload secret detection. Mock atomicity is not real
backup/restore acceptance; automatic retention, durable snapshots, notifications,
actual deletion and crash/power-loss recovery remain for their owning phases.

Local validation uses the explicitly selected Xcode 27 beta 6; hosted CI uses
macOS 15/Xcode 16.4. Builds do not establish UI, Intel, performance or signed
Keychain acceptance. Private specifications, parameters, cases and memory stay local.
Review or merge does not close Phase 0, DATA-001, DATA-000 or G5, authorize procurement,
or treat these synthetic tests as execution of the full acceptance catalog.
