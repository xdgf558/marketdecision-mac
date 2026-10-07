"""Exercise the real permission checker with synthetic codesign output, not OS access.

The temporary profile is only an existence fixture. These tests do not sign an app,
validate a provisioning profile, or establish native file-panel/Keychain behavior.
"""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import re
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / 'Scripts/check-demo-entitlements.py'
SANDBOX = 'com.apple.security.app-sandbox'
SELECTED = 'com.apple.security.files.user-selected.read-write'
CLIENT = 'com.apple.security.network.client'
BASE = {SANDBOX: True, SELECTED: True}
SERVICE = {SANDBOX: True, CLIENT: True}


class DemoPermissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='marketdecision-entitlements-')
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / 'Synthetic.app'
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.marketdecision.development'}))
        self.service = contents / 'XPCServices/SECNetworkService.xpc'
        service_contents = self.service / 'Contents'
        service_contents.mkdir(parents=True)
        (service_contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.marketdecision.sec-network',
            'CFBundlePackageType': 'XPC!', 'XPCService': {'ServiceType': 'Application'},
        }))
        self.profile = contents / 'embedded.provisionprofile'
        self.profile.write_bytes(b'synthetic existence fixture; not a provisioned profile')
        self.signed = dict(BASE, **{
            'com.apple.application-identifier': 'SYNTHETICTEAM.local.marketdecision.development',
            'com.apple.developer.team-identifier': 'SYNTHETICTEAM',
            'keychain-access-groups': ['SYNTHETICTEAM.local.marketdecision.development'],
        })

    def check(self, entitlements, provisioned=False, reject=False, failure=None,
              service_entitlements=None, service_team=None):
        read = ['codesign', '-d', '--entitlements', ':-', str(self.app)]
        verify = ['codesign', '--verify', '--strict', str(self.app)]
        service_read = ['codesign', '-d', '--entitlements', ':-', str(self.service)]
        service_verify = ['codesign', '--verify', '--strict', str(self.service)]
        app_details = ['codesign', '-d', '--verbose=4', str(self.app)]
        service_details = ['codesign', '-d', '--verbose=4', str(self.service)]
        calls = []

        def codesign(args, **kwargs):
            self.assertIn(args, [read, verify, service_read, service_verify, app_details, service_details])
            self.assertTrue(kwargs.get('check'))
            calls.append(args)
            if args == (read if failure == 'read' else verify if failure == 'verify' else
                        service_verify if failure == 'service_verify' else None):
                raise subprocess.CalledProcessError(1, args)
            if args in [app_details, service_details]:
                team = 'SYNTHETICTEAM' if provisioned else 'not set'
                if args == service_details and service_team is not None: team = service_team
                return subprocess.CompletedProcess(args, 0, stdout='', stderr='TeamIdentifier=' + team + '\n')
            value = entitlements if args == read else SERVICE if service_entitlements is None else service_entitlements
            return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps(value))

        arguments = [str(CHECKER), str(self.app)] + (['--provisioned'] if provisioned else [])
        output = io.StringIO()
        with patch('sys.argv', arguments), patch('subprocess.run', codesign), contextlib.redirect_stdout(output):
            if failure:
                with self.assertRaises(subprocess.CalledProcessError):
                    runpy.run_path(str(CHECKER), run_name='__main__')
            elif reject:
                with self.assertRaisesRegex(SystemExit, 'FAIL:'):
                    runpy.run_path(str(CHECKER), run_name='__main__')
            else:
                runpy.run_path(str(CHECKER), run_name='__main__')
        if reject or failure:
            self.assertNotIn('PASS:', output.getvalue())
        else:
            self.assertEqual(calls, [read, service_read, app_details, service_details, service_verify, verify])
            self.assertIn('PASS:', output.getvalue())

    def test_ordinary_production_permissions_pass(self):
        self.check(BASE)

    def test_existing_debugger_permission_passes(self):
        self.check(dict(BASE, **{'com.apple.security.get-task-allow': True}))

    def test_provisioned_identity_and_private_group_pass(self):
        self.check(self.signed, provisioned=True)

    def test_selected_permission_is_required(self):
        self.check({SANDBOX: True}, reject=True)

    def test_selected_permission_requires_boolean_true(self):
        for value in [False, 0, 1, 'true']:
            with self.subTest(value=value):
                self.check(dict(BASE, **{SELECTED: value}), reject=True)

    def test_sandbox_is_required_and_boolean_true(self):
        self.check({SELECTED: True}, reject=True)
        for value in [False, 0, 1, 'true']:
            with self.subTest(value=value):
                self.check(dict(BASE, **{SANDBOX: value}), reject=True)

    def test_network_server_is_rejected_even_when_provisioned(self):
        for key in ['com.apple.security.network.server']:
            with self.subTest(key=key):
                self.check(dict(BASE, **{key: True}), reject=True)
                self.check(dict(self.signed, **{key: True}), provisioned=True, reject=True)

    def test_production_network_client_is_rejected_even_false(self):
        for value in [True, False, 0, 1, 'true']:
            with self.subTest(value=value):
                self.check(dict(BASE, **{CLIENT: value}), reject=True)
                self.check(dict(self.signed, **{CLIENT: value}), provisioned=True, reject=True)

    def test_service_requires_exact_permissions(self):
        for key in [SANDBOX, CLIENT]:
            for value in [False, 0, 1, 'true', None]:
                with self.subTest(key=key, value=value):
                    permissions = dict(SERVICE)
                    if value is None: del permissions[key]
                    else: permissions[key] = value
                    self.check(BASE, service_entitlements=permissions, reject=True)
        for key, value in {
            SELECTED: True, 'keychain-access-groups': ['other.group'],
            'com.apple.security.inherit': True, 'com.apple.security.get-task-allow': True,
            'com.apple.security.network.server': True,
        }.items():
            with self.subTest(key=key):
                self.check(BASE, service_entitlements=dict(SERVICE, **{key: value}), reject=True)

    def test_service_presence_identity_and_team_are_required(self):
        self.check(BASE, service_team='OTHERTEAM', reject=True)
        self.check(self.signed, provisioned=True, service_team='OTHERTEAM', reject=True)
        info = self.service / 'Contents/Info.plist'
        original = info.read_bytes()
        for key, value in [('CFBundleIdentifier', 'other.service'), ('CFBundlePackageType', 'APPL'),
                           ('XPCService', {'ServiceType': 'System'})]:
            altered = plistlib.loads(original); altered[key] = value; info.write_bytes(plistlib.dumps(altered))
            self.check(BASE, reject=True)
        info.write_bytes(original)
        unexpected = self.service.parent / 'Unexpected.xpc'; unexpected.mkdir()
        self.check(BASE, reject=True); unexpected.rmdir()
        self.service.rename(self.service.with_suffix('.absent'))
        self.check(BASE, reject=True)

    def test_service_signature_failure_cannot_pass(self):
        self.check(BASE, failure='service_verify')

    def test_broad_file_and_persistent_access_are_rejected(self):
        extras = {
            'com.apple.security.temporary-exception.files.absolute-path.read-write': ['/'],
            'com.apple.security.temporary-exception.files.home-relative-path.read-write': ['/'],
            'com.apple.security.files.downloads.read-write': True,
            'com.apple.security.files.bookmarks.app-scope': True,
        }
        for key, value in extras.items():
            with self.subTest(key=key):
                self.check(dict(BASE, **{key: value}), reject=True)

    def test_ui_host_automation_exceptions_are_rejected_for_production(self):
        for key, value in {
            'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/'],
            'com.apple.security.temporary-exception.mach-lookup.global-name': ['com.apple.testmanagerd'],
        }.items():
            with self.subTest(key=key):
                self.check(dict(BASE, **{key: value}), reject=True)
                self.check(dict(self.signed, **{key: value}), provisioned=True, reject=True)

    def test_signing_identity_is_not_accepted_in_ordinary_mode(self):
        self.check(self.signed, reject=True)

    def test_provisioned_identity_must_match_bundle_and_team(self):
        for key, value in [
            ('com.apple.application-identifier', 'SYNTHETICTEAM.other.app'),
            ('com.apple.developer.team-identifier', 'OTHERTEAM'),
            ('com.apple.developer.team-identifier', ''),
        ]:
            with self.subTest(key=key, value=value):
                self.check(dict(self.signed, **{key: value}), provisioned=True, reject=True)

    def test_provisioned_group_must_be_exactly_private_application_group(self):
        for groups in [[], ['other.group'], self.signed['keychain-access-groups'] + ['other.group']]:
            with self.subTest(groups=groups):
                self.check(dict(self.signed, **{'keychain-access-groups': groups}), provisioned=True, reject=True)

    def test_provisioned_profile_must_exist(self):
        self.profile.unlink()
        self.check(self.signed, provisioned=True, reject=True)

    def test_codesign_read_failure_cannot_pass(self):
        self.check(BASE, failure='read')

    def test_codesign_strict_verification_failure_cannot_pass(self):
        self.check(BASE, failure='verify')


class EntitlementSourceIsolationTests(unittest.TestCase):
    def test_source_plists_contain_only_the_intended_permissions(self):
        expected = {
            'MarketDecision.entitlements': BASE,
            'MarketDecision-Signed.entitlements': dict(BASE, **{
                'keychain-access-groups': ['$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'],
            }),
            'MarketDecision-UIHost.entitlements': {SANDBOX: True},
            'SECNetworkService.entitlements': SERVICE,
            'MarketDecision-FileAcceptance.entitlements': {SANDBOX: True, SELECTED: True},
        }
        for filename, keys in expected.items():
            with self.subTest(filename=filename):
                actual = plistlib.loads((ROOT / 'App' / filename).read_bytes())
                self.assertEqual(actual, keys)
                self.assertIs(actual[SANDBOX], True)
                if SELECTED in keys:
                    self.assertIs(actual[SELECTED], True)
                if CLIENT in keys:
                    self.assertIs(actual[CLIENT], True)

    def test_host_debug_release_use_the_isolated_entitlement_file(self):
        project = (ROOT / 'App/MarketDecision.xcodeproj/project.pbxproj').read_text()
        configurations = re.findall(
            r'isa = XCBuildConfiguration;\s*buildSettings = \{(.*?)\};\s*name = (\w+);\s*\};',
            project, re.DOTALL)
        for bundle, expected in [
            ('local.marketdecision.ui-test-host', 'MarketDecision-UIHost.entitlements'),
            ('local.marketdecision.file-acceptance', 'MarketDecision-FileAcceptance.entitlements'),
            ('local.marketdecision.development', '"$(MARKETDECISION_APP_ENTITLEMENTS)"'),
            ('local.marketdecision.sec-network', 'SECNetworkService.entitlements'),
        ]:
            with self.subTest(bundle=bundle):
                selected = [(settings, name) for settings, name in configurations
                            if re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*' + re.escape(bundle) + r'\s*;', settings)]
                self.assertEqual(sorted(name for _, name in selected), ['Debug', 'Release'])
                for settings, _ in selected:
                    self.assertEqual(re.findall(r'CODE_SIGN_ENTITLEMENTS\s*=\s*([^;]+);', settings), [expected])
                    if bundle == 'local.marketdecision.development':
                        self.assertIn('MARKETDECISION_APP_ENTITLEMENTS = MarketDecision.entitlements;', settings)
                    if bundle == 'local.marketdecision.sec-network':
                        self.assertIn('CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;', settings)

    def test_only_production_embeds_and_depends_on_network_service(self):
        project = ROOT / 'App/MarketDecision.xcodeproj/project.pbxproj'
        objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))['objects']
        targets = {value['name']: value for value in objects.values() if value.get('isa') == 'PBXNativeTarget'}
        service = targets['SECNetworkService']
        product = service['productReference']
        self.assertEqual(service['productType'], 'com.apple.product-type.xpc-service')
        for name in ['MarketDecision', 'MarketDecisionUITestHost', 'MarketDecisionFileAcceptance']:
            target = targets[name]
            copies = [objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXCopyFilesBuildPhase']
            dependencies = [objects[d]['target'] for d in target['dependencies']]
            if name == 'MarketDecision':
                self.assertEqual(len(copies), 1)
                self.assertEqual(copies[0]['dstPath'], '$(CONTENTS_FOLDER_PATH)/XPCServices')
                self.assertEqual(str(copies[0]['dstSubfolderSpec']), '16')
                self.assertEqual([objects[f]['fileRef'] for f in copies[0]['files']], [product])
                self.assertIn('CodeSignOnCopy', objects[copies[0]['files'][0]]['settings']['ATTRIBUTES'])
                self.assertEqual(len(dependencies), 1)
                self.assertIs(objects[dependencies[0]], service)
            else:
                self.assertEqual(copies, [])
                self.assertEqual(dependencies, [])
        helper_products = [objects[d]['productName'] for d in service['packageProductDependencies']]
        self.assertEqual(helper_products, ['SECNetworkBroker'])

    def test_build_scripts_do_not_override_helper_entitlements(self):
        for name in ['verify-ci.sh', 'build-signed-local.sh', 'verify-local.sh']:
            text = (ROOT / 'Scripts' / name).read_text()
            self.assertNotRegex(text, r'(?m)\sCODE_SIGN_ENTITLEMENTS=')



if __name__ == '__main__':
    unittest.main()
