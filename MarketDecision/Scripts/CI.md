# Public foundation CI

The workflow runs on pull requests, pushes to main, and manual dispatch. It uses the standard `macos-15` runner and explicitly selects Xcode 16.4. Runner image revisions may change; the log records the actual Xcode, Swift, OS and architecture. This differs from local Xcode 27 beta 6 and does not change the local toolchain or release policy.

The read-only workflow checks out the clean public repository with no persisted credential, custom cache, artifacts, secrets, signing account or provisioning profile. It runs the small public source tests, four UTC tests and module boundary checks, then builds arm64 Debug and Release using ad-hoc signatures. Effective App Sandbox and user-selected-file read/write entitlements, the absence of network/broad-file permissions, and Release diagnostic markers are checked. Ad-hoc signing is not unsigned output, account signing, notarization, or Keychain qualification.

The Keychain integration test is explicitly disabled. The summary says NOT EXECUTED, even if all other tests pass. The workflow does not invoke the account-signed Keychain host, application diagnostic, performance, or full private acceptance suites. A separate step runs seven native interaction cases in an in-memory synthetic host; file-picker operations are not part of those cases. The checker requires the exact case set, zero failures/skips and the exact host entitlement set. The host uses its own sandbox-only source entitlement file, retaining the existing exact Xcode automation exception set; production user-selected-file access is not inherited by the host. These host exceptions never qualify production permissions. Production file-panel reads/writes remain separately executed target-platform evidence and are not reported as a pass by this workflow. Phase 0, DATA-001 and private traceability are not automatically closed. CI logs are public and contain build/test output from public source; no build or log artifact is uploaded. The tracked-file guard is defense in depth, not a guarantee against arbitrary secrets in source; clean publication review remains required.

To reproduce against a clean public checkout with an explicit local Xcode path:

```sh
DEVELOPER_DIR='/path/to/Xcode.app/Contents/Developer' bash MarketDecision/Scripts/verify-ci.sh all
```

`tests` and `builds` can be run separately. The script rejects the private planning repository before build or test execution. It never requests provisioning updates or buys hosted capacity. Branch protection is not changed by this workflow; a required check must only be configured after its real run and review.
