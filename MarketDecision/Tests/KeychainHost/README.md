# Keychain signed-host verification

This optional integration host compiles the production CredentialStore directly. It uses a fresh synthetic service, checks create/read/update/delete and the stored device-only accessibility, then deletes its fixture. It does not read application credentials or replace the default Swift test runner.

Run from the project root with an existing macOS provisioning profile and a certificate authorized by that profile:

```sh
DEVELOPER_DIR='/path/to/Xcode.app/Contents/Developer' \
KEYCHAIN_PROFILE='/path/to/macOS.provisionprofile' \
KEYCHAIN_SIGN_IDENTITY='certificate SHA-1' \
bash MarketDecision/Scripts/verify-keychain.sh
```

The profile must authorize `local.marketdecision.keychainprobe` and its matching keychain group. The script rejects iOS, expired, wrong-identity and wrong-bundle profiles before signing. Profiles, certificate identities and account details must stay local. It does not obtain profiles, enroll accounts or enable network/file permissions in the test host.

Compilation or a rejected profile is not a Keychain pass. A successful probe also does not qualify the application signature, cross-launch persistence or all DATA-001 requirements. The real application separately needs a macOS profile authorizing its own bundle identifier `local.marketdecision.development`; do not reuse the probe identity for the application. No fallback to file-based Keychain or plaintext is allowed on a signing failure.

To build the actual application with its own provisioned identity:

```sh
DEVELOPER_DIR='/path/to/Xcode.app/Contents/Developer' \
MARKETDECISION_SIGNING_TEAM='your team ID' \
bash MarketDecision/Scripts/build-signed-local.sh
```

This opt-in command uses the account already logged in to Xcode to update provisioning and register the local test device if necessary. It builds arm64 Debug into `DerivedDataProvision`, verifies the effective sandbox permissions and the app-specific Keychain group, and leaves the default ad-hoc demo build unchanged. It does not purchase membership. Never commit generated profiles, certificates, DerivedData or account details. The team ID is supplied locally, not stored in the project.

A profile created for the actual app may also authorize the probe if its application identifier and Keychain groups use the corresponding team wildcard. The probe script validates this before signing. A profile restricted to the application alone cannot be reused as the probe identity.

## Actual application process and restart checks

After building the signed Debug application, run:

```sh
bash MarketDecision/Scripts/verify-app-keychain.sh
```

This invokes the actual application executable in an explicit Debug-only diagnostic mode before creating the UI or business database. Three sequential processes share one random, synthetic-only service: create/read/update and attribute readback; restart/read/delete; restart/absence. Each invocation is limited to 30 seconds, must exit successfully, and prints its PID. An EXIT cleanup attempts deletion even after failure; cleanup failure fails the script and preserves the random run identifier in output for manual retry. No real credential reference or secret is accepted as input. Release excludes the diagnostic implementation and dispatch.

Both device-only accessibility and synchronizable=false are checked from returned item attributes. The attribute query allows either synchronization state, so it does not assume the answer from its query filter. Missing attributes are errors. The regular Swift test Keychain case remains opt-in; this executable test does not make a skipped test pass. These checks cover app-executable diagnostic processes, not UI-driven provider workflows, lock/unlock, backup, system reboot, or the complete DATA-001 contract.

`test_profile_time.py` covers naive UTC plist dates, equivalent timezone offsets, exact expiration boundaries and invalid values. `profile_time.py` normalizes both naive and timezone-aware dates to UTC before comparison.
