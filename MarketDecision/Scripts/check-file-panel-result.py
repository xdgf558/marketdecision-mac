"""Fail closed on missing native file-panel execution or enlarged app permissions."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from foundation_traceability import input_hashes

EXPECTED = {
    'testFileExportWritesMarkdownAndZIPAndCancelPreservesState',
    'testFileImportRejectsCorruptionAndMergeKeepsConflict',
    'testReplaceAndClearPersistAcrossRelaunch',
}
APP_ID = 'local.marketdecision.file-acceptance'


def validate_permissions(identity, entitlements):
    required = {'com.apple.security.app-sandbox',
                'com.apple.security.files.user-selected.read-write'}
    if identity != APP_ID or set(entitlements) != required or any(entitlements[k] is not True for k in required):
        raise ValueError('FAIL: file acceptance app must use the exact file-only permission set, no network, and isolated identity')


def check_app(path):
    path = Path(path)
    info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
    if (path / 'Contents/XPCServices').exists():
        raise ValueError('FAIL: file acceptance app must not embed a network helper')
    signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True)
    entitlements = plistlib.loads(signed.stdout)
    validate_permissions(info['CFBundleIdentifier'], entitlements)
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
    subprocess.run([sys.executable, str(Path(__file__).with_name('check-release-isolation.py')), str(path)], check=True)
    executable = path / 'Contents/MacOS' / info['CFBundleExecutable']
    return {'bundle_id': info['CFBundleIdentifier'], 'entitlements': entitlements,
            'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}


def validate_project(project):
    objects = project['objects']
    targets = {value['name']: value for value in objects.values() if value.get('isa') == 'PBXNativeTarget'}
    def source_paths(target):
        return {objects[objects[file]['fileRef']]['path']
                for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
                for file in objects[phase]['files']}
    production, acceptance = targets['MarketDecision'], targets['MarketDecisionFileAcceptance']
    if source_paths(production) != source_paths(acceptance):
        raise ValueError('FAIL: acceptance app does not compile the exact production source set')
    def products(target):
        return {objects[reference]['productName'] for reference in target.get('packageProductDependencies', [])}
    if products(production) != products(acceptance):
        raise ValueError('FAIL: acceptance app package dependencies differ')
    # The file-panel app shares production views, dependencies and Release conditions,
    # but does not embed the production app's separately sandboxed network service.
    if acceptance.get('dependencies') or any(objects[p]['isa'] == 'PBXCopyFilesBuildPhase'
                                               for p in acceptance['buildPhases']):
        raise ValueError('FAIL: file acceptance app must not depend on or embed a helper')
    for target, entitlement_file in [(production, 'MarketDecision.entitlements'),
                                     (acceptance, 'MarketDecision-FileAcceptance.entitlements')]:
        configurations = [objects[c] for c in objects[target['buildConfigurationList']]['buildConfigurations']]
        def configured_entitlement(settings):
            value = settings.get('CODE_SIGN_ENTITLEMENTS')
            if target is production:
                if value != '$(MARKETDECISION_APP_ENTITLEMENTS)': return None
                return settings.get('MARKETDECISION_APP_ENTITLEMENTS')
            return value
        if any(configured_entitlement(c['buildSettings']) != entitlement_file for c in configurations):
            raise ValueError('FAIL: target must keep its own production/file-only entitlement file in every configuration')
        settings = next(c['buildSettings'] for c in configurations if c['name'] == 'Release')
        if (settings.get('CODE_SIGN_INJECT_BASE_ENTITLEMENTS') != 'NO'
                or settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '')
                or settings.get('ENABLE_HARDENED_RUNTIME') != 'YES'):
            raise ValueError('FAIL: acceptance must preserve production Release compilation conditions and its narrower file-only permissions')


def check_project():
    project = Path(__file__).resolve().parents[1] / 'App/MarketDecision.xcodeproj/project.pbxproj'
    validate_project(json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)])))


def fingerprints():
    root = Path(__file__).resolve().parents[1]
    hashes = input_hashes(root)
    for folder in ['NativeUITests', 'App/MarketDecision.xcodeproj/xcshareddata/xcschemes']:
        for path in (root / folder).rglob('*'):
            if path.is_file():
                hashes[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def validate_results(summary, tests):
    if (summary.get('totalTestCount') != len(EXPECTED) or summary.get('passedTests') != len(EXPECTED)
            or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0):
        raise ValueError('FAIL: file-panel acceptance requires exactly three passes and zero skips/failures')
    cases = {}
    def visit(node):
        if isinstance(node, dict):
            name = node.get('name', '').removesuffix('()')
            if name in EXPECTED:
                if name in cases:
                    raise ValueError('FAIL: duplicate file-panel result')
                cases[name] = node.get('result')
            for value in node.values():
                if isinstance(value, (dict, list)):
                    visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)
    visit(tests)
    if set(cases) != EXPECTED or any(value != 'Passed' for value in cases.values()):
        raise ValueError('FAIL: file-panel case identity/status differs; review xcresult schema')
    return cases


def main():
    # Even a failed project/signature/xcresult preflight must remove an old PASS.
    if len(sys.argv) == 4:
        Path(sys.argv[2]).unlink(missing_ok=True)
    check_project()
    if len(sys.argv) == 3 and sys.argv[1] in {'--inputs', '--verify-inputs'}:
        path = Path(sys.argv[2])
        current = fingerprints()
        if sys.argv[1] == '--inputs': path.write_text(json.dumps(current, sort_keys=True) + '\n')
        elif json.loads(path.read_text()) != current:
            raise ValueError('FAIL: file-panel verification inputs changed during execution')
        return
    if len(sys.argv) == 3 and sys.argv[1] == '--app-only':
        check_app(sys.argv[2])
        print('PASS: isolated app has exact file-only Release permissions, no network and no diagnostic markers')
        return
    bundle, report, app = sys.argv[1:]
    def get(kind):
        return json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', bundle]))
    cases = validate_results(get('summary'), get('tests'))
    payload = {'status': 'PASS', 'executed': cases, 'skipped': 0, 'app': check_app(app), 'source_sha256': fingerprints(),
               'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
               'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
               'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
               'scope': 'PRODUCTION_SOURCE_RELEASE_ISOLATED_CONTAINER_SYNTHETIC_RESEARCH_ACTUAL_FILE_PANELS',
               'network': 'DISABLED_BY_ENTITLEMENT',
               'keychain': 'NOT_EXECUTED', 'real_data_backup': 'NOT_ADMITTED',
               'voiceover': 'NOT_EXECUTED', 'ime_composition': 'NOT_EXECUTED'}
    Path(report).write_text(json.dumps(payload, indent=2) + '\n')
    print('PASS: three actual file-panel cases executed with isolated persisted data and file-only Release permissions; no network qualification')


if __name__ == '__main__':
    main()
