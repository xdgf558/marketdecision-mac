"""Verify production's process split from effective signatures, never source plists alone.

The app has no network entitlement. Only the exact SEC and Equity XPC services have
outbound access; each enforces its own closed endpoint policy. The entitlement itself is
process-wide and must never be described as an OS host allowlist.
"""
import pathlib
import plistlib
import subprocess
import sys

APP_ID = 'local.marketdecision.development'
SERVICES = {'SECNetworkService.xpc': 'local.marketdecision.sec-network',
            'EquityNetworkService.xpc': 'local.marketdecision.equity-network'}
SANDBOX = 'com.apple.security.app-sandbox'
SELECTED = 'com.apple.security.files.user-selected.read-write'
CLIENT = 'com.apple.security.network.client'
SIGNING_IDENTITY = {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}


def signed_entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def signature_team(path, expected_identifier):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True, check=True)
    identifiers = [line.removeprefix('Identifier=') for line in result.stderr.splitlines() if line.startswith('Identifier=')]
    teams = [line.removeprefix('TeamIdentifier=') for line in result.stderr.splitlines() if line.startswith('TeamIdentifier=')]
    if identifiers != [expected_identifier]:
        raise SystemExit('FAIL: code signing identifier does not match the expected bundle identity')
    if len(teams) != 1 or not teams[0]:
        raise SystemExit('FAIL: missing unambiguous signing team')
    return teams[0]


app = pathlib.Path(sys.argv[1])
provisioned = len(sys.argv) == 3 and sys.argv[2] == '--provisioned'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != APP_ID:
    raise SystemExit('FAIL: unexpected production bundle identity')
entitlements = signed_entitlements(app)
allowed = {SANDBOX, SELECTED, 'com.apple.security.get-task-allow'}
if provisioned:
    allowed |= SIGNING_IDENTITY | {'keychain-access-groups'}
    team = entitlements.get('com.apple.developer.team-identifier')
    identity = entitlements.get('com.apple.application-identifier')
    if not team or identity != team + '.' + APP_ID or entitlements.get('keychain-access-groups') != [identity]:
        raise SystemExit('FAIL: signing identity and private keychain group do not match')
    if not (app / 'Contents/embedded.provisionprofile').is_file():
        raise SystemExit('FAIL: missing embedded provisioning profile')
if (entitlements.get(SANDBOX) is not True or entitlements.get(SELECTED) is not True
        or set(entitlements) - allowed):
    raise SystemExit('FAIL: production app must have sandbox/selected-file permissions and no network entitlement')

services = app / 'Contents/XPCServices'
if (services.is_symlink() or not services.is_dir()
        or set(item.name for item in services.iterdir()) != set(SERVICES)):
    raise SystemExit('FAIL: production must embed exactly the SEC and Equity network services')
app_team = signature_team(app, APP_ID)
if (provisioned and app_team != team) or (not provisioned and app_team != 'not set'):
    raise SystemExit('FAIL: production signature does not match the selected signing mode')
for filename, service_id in SERVICES.items():
    service = services / filename
    if service.is_symlink() or not service.is_dir():
        raise SystemExit('FAIL: network service must be an embedded directory, not a symlink')
    service_info = plistlib.loads((service / 'Contents/Info.plist').read_bytes())
    if (service_info.get('CFBundleIdentifier') != service_id or service_info.get('CFBundlePackageType') != 'XPC!'
            or service_info.get('XPCService') != {'ServiceType': 'Application'}):
        raise SystemExit('FAIL: unexpected network service identity or lifecycle declaration')
    service_entitlements = signed_entitlements(service)
    service_allowed = {SANDBOX, CLIENT} | (SIGNING_IDENTITY if provisioned else set())
    if (service_entitlements.get(SANDBOX) is not True or service_entitlements.get(CLIENT) is not True
            or set(service_entitlements) - service_allowed):
        raise SystemExit('FAIL: each network service requires exactly sandbox/outbound permissions; no files, keychain, inheritance or debugging')
    if SIGNING_IDENTITY & set(service_entitlements):
        if (service_entitlements.get('com.apple.developer.team-identifier') != team
                or service_entitlements.get('com.apple.application-identifier') != team + '.' + service_id):
            raise SystemExit('FAIL: network service signing metadata does not match production')
    if signature_team(service, service_id) != app_team:
        raise SystemExit('FAIL: production and network service signing teams differ')
    subprocess.run(['codesign', '--verify', '--strict', str(service)], check=True)
subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True)
print('PASS: production main has no network entitlement; exactly two separately sandboxed SEC/Equity services own outbound access')
