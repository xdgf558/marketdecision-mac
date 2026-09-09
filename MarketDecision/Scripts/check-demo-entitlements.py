"""Verify the effective demo signature, not just its source entitlement file."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True)
entitlements = plistlib.loads(result.stdout)
allowed = {'com.apple.security.app-sandbox', 'com.apple.security.get-task-allow'}
if len(sys.argv) == 3 and sys.argv[2] == '--provisioned':
    allowed |= {'com.apple.application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups'}
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    team = entitlements.get('com.apple.developer.team-identifier')
    identity = entitlements.get('com.apple.application-identifier')
    if not team or identity != team + '.' + info['CFBundleIdentifier'] or entitlements.get('keychain-access-groups') != [identity]:
        raise SystemExit('FAIL: signing identity and private keychain group do not match')
    if not (app / 'Contents/embedded.provisionprofile').is_file():
        raise SystemExit('FAIL: missing embedded provisioning profile')
if entitlements.get('com.apple.security.app-sandbox') is not True or set(entitlements) - allowed:
    raise SystemExit('FAIL: unexpected demo signing permissions')
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
print('PASS: signed demo sandbox enabled; no network or user-file entitlement')
