# Credential settings review

The native settings form can now save, replace and delete one reserved data-service credential in the data-protection Keychain. It does not connect a provider or validate a credential against a service. The demo connection button remains a synthetic-only operation.

The shared settings model queries presence without requesting secret bytes. Unknown, absent and saved are distinct states. Operations serialize through a busy guard; failure clears any assumed presence and reports an explicit error. A subsequent presence check permits recovery. No raw errors or credentials are logged by this flow.

Input uses SecureField and stays in transient view state. Submission clears the field even when saving fails; leaving the view or making the scene inactive clears the draft. This is not a memory-zeroization guarantee. Stored credentials are never populated into the input or offered for copy/export. Replacement and deletion require native confirmation. Settings windows share operation status, not draft contents.

Public synthetic tests cover lifecycle and model recreation, exact input byte preservation, whitespace rejection, failures and recovery. They use an in-memory store, not a real Keychain. The ordinary real-Keychain test remains opt-in and skipped by default; a skip is not a pass.

Local signed Debug UI checks used disposable synthetic credentials: save, replace/cancel, quit/reopen presence, delete/cancel, and reopen absence. The fixture was removed. The standalone settings window was checked for visible layout and clearing an abandoned draft. A local unsigned-by-account build exercised write failure and recovery status. These are local observations, not tests automatically reproduced by public CI; private screenshots and signing material are excluded.

Local verification: 26 regular Swift tests passed, one real-Keychain test skipped, four UTC tests passed, module boundaries passed, default and Apple Development arm64 Debug builds passed with entitlement checks. CI results for this change must be read from the actual PR checks; earlier CI success is not evidence for this head.

This slice does not close Phase 0 or DATA-001. Full keyboard/VoiceOver, minimum-window coverage, lock/unlock, system restart, backup/recovery, Intel and target-macOS UI/runtime evidence remain open. No procurement, real credentials, provider access, paid API, new financial phase or release qualification is introduced. The all-rights-reserved license is unchanged.
