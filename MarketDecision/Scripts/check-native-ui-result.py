"""Require actual execution of the fixed native suite; never count skipped/empty UI runs."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

expected = {
    'testReturnDoesNotSaveAndTabSkipsDisabledControls',
    'testNativeReplaceDeleteRequireExplicitKeysAndRestoreFocus',
    'testIndependentSettingsSharesStateAndInvalidatesOldSheet',
    'testFailedSaveRequiresCheckBeforeRetry',
}

def validate_host_entitlements(bundle_id, entitlements):
    # Xcode adds these automation exceptions to the separate UI host. Never
    # accept them for the shipping bundle or broaden the production verifier.
    keys = {'com.apple.security.app-sandbox', 'com.apple.security.get-task-allow',
            'com.apple.security.temporary-exception.files.absolute-path.read-only',
            'com.apple.security.temporary-exception.mach-lookup.global-name'}
    services = entitlements.get('com.apple.security.temporary-exception.mach-lookup.global-name')
    if (bundle_id != 'local.marketdecision.ui-test-host' or set(entitlements) != keys
        or entitlements.get('com.apple.security.app-sandbox') is not True
        or entitlements.get('com.apple.security.get-task-allow') is not True
        or entitlements.get('com.apple.security.temporary-exception.files.absolute-path.read-only') != ['/']
        or not isinstance(services, list) or len(services) != 3
        or set(services) != {'com.apple.testmanagerd', 'com.apple.dt.testmanagerd.runner', 'com.apple.coresymbolicationd'}):
        raise ValueError('FAIL: unexpected UI-host identity or automation permissions; keys=' + ','.join(sorted(entitlements)))

def check_host(app):
    app = Path(app)
    identity = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True)
    validate_host_entitlements(identity, plistlib.loads(signed.stdout))
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    print('PASS: isolated UI-host sandbox with exact Xcode read-only-root/test-service exceptions; no network entitlement')
def validate_results(summary, tests):
    if summary.get('totalTestCount') != len(expected) or summary.get('passedTests') != len(expected) or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
        raise ValueError('FAIL: incomplete native UI execution; summary did not report exactly four passes and zero failures/skips')
    # Verify names and statuses from terminal test-case nodes, not just the console/aggregate.
    cases = {}
    def visit(node):
        if isinstance(node, dict):
            name = node.get('name', '').removesuffix('()')
            if name in expected:
                if name in cases:
                    raise ValueError('FAIL: duplicate native test result')
                cases[name] = node.get('result')
            for value in node.values():
                if isinstance(value, (dict, list)): visit(value)
        elif isinstance(node, list):
            for value in node: visit(value)
    visit(tests)
    if set(cases) != expected or any(result != 'Passed' for result in cases.values()):
        raise ValueError('FAIL: native test case identity/status differs; review xcresult schema rather than assuming success')
    return cases

def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--host-only':
        check_host(sys.argv[2])
        return
    bundle, report, app = sys.argv[1:]
    check_host(app)
    def get(kind):
        return json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', bundle]))
    cases = validate_results(get('summary'), get('tests'))
    payload = {'status': 'PASS', 'executed': cases, 'skipped': 0,
               'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
               'scope': 'SHARED_PRODUCTION_VIEWS_SYNTHETIC_MEMORY_HOST',
               'keychain': 'NOT_EXECUTED', 'voiceover': 'NOT_EXECUTED', 'ime_composition': 'NOT_EXECUTED'}
    Path(report).write_text(json.dumps(payload, indent=2) + '\n')
    print('PASS: four native UI cases actually executed; no skips; synthetic memory host only')

if __name__ == "__main__":
    main()
