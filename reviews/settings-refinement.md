# Settings composition and interaction review

The settings model previously constructed its own credential store. It now comes from `AppEnvironment.makeCredentialSettings()`, using the environment's injected `CredentialStorage`. The model initializer requires an explicit store. Workspace and standalone settings share the resulting model; environment preparation runs through the guarded refresh entry point. A preparation failure exposes a retry state and does not fall back to another credential store.

A synthetic test constructs an environment with an in-memory store, saves through one settings model, observes the value through that store and a second model, then deletes and observes absence. It does not exercise a real Keychain. There are now 27 regular Swift tests; the ordinary real-Keychain test remains skipped by default and is not a pass.

Keyboard entry points are Command-1/2 for sidebar pages, Command-L for credential input, Command-S or input Return for save/replacement confirmation, Shift-Command-Backspace for deletion confirmation, and Shift-Command-R for presence refresh. Replacement and deletion retain confirmation. Secure input now has an explicit accessibility label and hint. Stored secrets are still not read back into the UI.

Local signed UI observations used synthetic credentials: shortcut save and replacement/escape/retry, presence after app restart, deletion and subsequent restart absence. Deletion was confirmed by clicking the native destructive action; Return did not implicitly activate it. These observations do not establish complete keyboard-only operation.

The minimum settings window and light/dark layouts were visually checked, together with the standalone settings window. Screenshots and design notes remain private. These are scoped visual observations, not full accessibility or target-platform acceptance.

Full Tab order and VoiceOver remain unverified. System keyboard navigation was initially off; enabling it permitted a limited Tab check but did not establish the complete sequence. A forced-focus attempt also focused disabled controls and was removed. VoiceOver was observed on temporarily, then off before reliable reader navigation could be established; no speech or reader completion is claimed. The keyboard preference was restored and VoiceOver was observed off. Existing lock/restart/backup, Intel, target-macOS UI and performance gaps remain open.

CI checkout moves to the fixed official v5.1.0 commit `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09`, whose action uses Node 24. `contents: read`, `persist-credentials: false`, depth 1, and the existing signing/artifact restrictions remain unchanged. Sources: [official release](https://github.com/actions/checkout/releases/tag/v5.1.0), [pinned action definition](https://github.com/actions/checkout/blob/fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09/action.yml).

Local clean-checkout tests, UTC/boundary checks, arm64 Debug/Release builds, entitlement checks and Release marker checks passed. Read this PR's actual checks for hosted CI evidence; local UI observations are not automatically reproduced by CI.

This review does not close Phase 0 or DATA-001, authorize procurement or the next phase, or change the all-rights-reserved license.
