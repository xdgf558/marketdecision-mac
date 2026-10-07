"""Verify production's process split from effective signatures, never source plists alone.

The app has no network entitlement. Only the exact embedded SEC XPC service has
outbound access; its code enforces SEC destinations. The entitlement itself is
process-wide and must never be described as an OS host allowlist.
"""
import pathlib
import plistlib
import subprocess
import sys

APP_ID = 'local.marketdecision.development'
SERVICE_ID = 'local.marketdecision.sec-network'
SANDBOX = 'com.apple.security.app-sandbox'
SELECTED = 'com.apple.security.files.user-selected.read-write'
CLIENT = 'com.apple.security.network.client'
SIGNING_IDENTITY = {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}


def signed_entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True)
    return plistlib.loads(result.stdout)


def signature_team(path):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True, check=True)
    teams = [line.removeprefix('TeamIdentifier=') for line in result.stderr.splitlines() if line.startswith('TeamIdentifier=')]
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
service = services / 'SECNetworkService.xpc'
if (not services.is_dir() or set(item.name for item in services.iterdir()) != {service.name}
        or service.is_symlink() or not service.is_dir()):
    raise SystemExit('FAIL: production must embed exactly the SEC network service')
service_info = plistlib.loads((service / 'Contents/Info.plist').read_bytes())
if (service_info.get('CFBundleIdentifier') != SERVICE_ID or service_info.get('CFBundlePackageType') != 'XPC!'
        or service_info.get('XPCService') != {'ServiceType': 'Application'}):
    raise SystemExit('FAIL: unexpected SEC service identity or lifecycle declaration')
service_entitlements = signed_entitlements(service)
service_allowed = {SANDBOX, CLIENT} | (SIGNING_IDENTITY if provisioned else set())
if (service_entitlements.get(SANDBOX) is not True or service_entitlements.get(CLIENT) is not True
        or set(service_entitlements) - service_allowed):
    raise SystemExit('FAIL: SEC service must have exactly sandbox/outbound permissions; no files, keychain, inheritance or debugging')
if SIGNING_IDENTITY & set(service_entitlements):
    if (service_entitlements.get('com.apple.developer.team-identifier') != team
            or service_entitlements.get('com.apple.application-identifier') != team + '.' + SERVICE_ID):
        raise SystemExit('FAIL: SEC service signing metadata does not match production')
app_team, service_team = signature_team(app), signature_team(service)
if app_team != service_team or (provisioned and app_team != team) or (not provisioned and app_team != 'not set'):
    raise SystemExit('FAIL: production and SEC service signing teams differ')
subprocess.run(['codesign', '--verify', '--strict', str(service)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
print('PASS: production app has no network entitlement; exact separately sandboxed SEC service owns outbound access')
