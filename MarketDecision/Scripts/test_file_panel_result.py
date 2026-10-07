"""Mutation tests for evidence and permission accounting, not native execution."""
import copy
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('file_panel_result', Path(__file__).with_name('check-file-panel-result.py'))
result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(result)


class FilePanelEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.summary = dict(totalTestCount=3, passedTests=3, failedTests=0, skippedTests=0)
        self.tree = {'testNodes': [{'name': name + '()', 'result': 'Passed'} for name in sorted(result.EXPECTED)]}
        self.permissions = {'com.apple.security.app-sandbox': True,
                            'com.apple.security.files.user-selected.read-write': True}

    def test_exact_evidence_accepted(self):
        self.assertEqual(set(result.validate_results(self.summary, self.tree)), result.EXPECTED)
        result.validate_permissions(result.APP_ID, self.permissions)
        source = Path(__file__).resolve().parents[1] / 'App/MarketDecision-FileAcceptance.entitlements'
        actual = plistlib.loads(source.read_bytes())
        self.assertEqual(actual, self.permissions)
        result.validate_permissions(result.APP_ID, actual)
        self.assertIn('App/MarketDecision-FileAcceptance.entitlements', result.fingerprints())

    def test_skip_failure_empty_or_unknown_summary_rejected(self):
        for key in self.summary:
            summary = dict(self.summary, **{key: self.summary[key] + 1})
            with self.assertRaises(ValueError):
                result.validate_results(summary, self.tree)
        with self.assertRaises(ValueError):
            result.validate_results({}, self.tree)

    def test_wrong_missing_duplicate_or_skipped_case_rejected(self):
        for mutation in range(4):
            tree = copy.deepcopy(self.tree)
            if mutation == 0: tree['testNodes'][0]['name'] = 'unrelatedTest()'
            elif mutation == 1: tree['testNodes'].pop()
            elif mutation == 2: tree['testNodes'].append(tree['testNodes'][0])
            else: tree['testNodes'][0]['result'] = 'Skipped'
            with self.assertRaises(ValueError):
                result.validate_results(self.summary, tree)

    def test_production_or_memory_host_identity_rejected(self):
        for identity in ['local.marketdecision.development', 'local.marketdecision.ui-test-host', '']:
            with self.assertRaises(ValueError):
                result.validate_permissions(identity, self.permissions)

    def test_extra_or_missing_permissions_rejected(self):
        for key in ['com.apple.security.network.client', 'com.apple.security.network.server', 'com.apple.security.get-task-allow',
                    'com.apple.security.temporary-exception.files.absolute-path.read-only',
                    'com.apple.security.temporary-exception.mach-lookup.global-name']:
            with self.assertRaises(ValueError):
                result.validate_permissions(result.APP_ID, dict(self.permissions, **{key: True}))
        for key in self.permissions:
            changed = dict(self.permissions); del changed[key]
            with self.assertRaises(ValueError):
                result.validate_permissions(result.APP_ID, changed)

    def test_permissions_must_be_boolean_true(self):
        for key in self.permissions:
            for value in [False, 1, 'true', None]:
                with self.assertRaises(ValueError):
                    result.validate_permissions(result.APP_ID, dict(self.permissions, **{key: value}))

    def test_acceptance_configuration_cannot_change_source_or_permissions(self):
        project_path = Path(__file__).resolve().parents[1] / 'App/MarketDecision.xcodeproj/project.pbxproj'
        original = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_path)]))
        result.validate_project(original)
        for mutation in ['source', 'package', 'permissions', 'network_permissions', 'debug_permissions', 'conditions', 'helper_dependency', 'helper_embedding']:
            project = copy.deepcopy(original)
            objects = project['objects']
            target = next(v for v in objects.values() if v.get('name') == 'MarketDecisionFileAcceptance' and v.get('isa') == 'PBXNativeTarget')
            if mutation == 'source':
                phase = next(objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase')
                phase['files'].pop()
            elif mutation == 'package': target['packageProductDependencies'] = []
            elif mutation == 'helper_dependency': target['dependencies'] = ['E00000000000000000000011']
            elif mutation == 'helper_embedding': target['buildPhases'].append('E00000000000000000000010')
            else:
                configuration = 'Debug' if mutation == 'debug_permissions' else 'Release'
                settings = next(objects[c]['buildSettings'] for c in objects[target['buildConfigurationList']]['buildConfigurations'] if objects[c]['name'] == configuration)
                if mutation == 'permissions': settings['CODE_SIGN_ENTITLEMENTS'] = 'MarketDecision-UIHost.entitlements'
                elif mutation in ['network_permissions', 'debug_permissions']: settings['CODE_SIGN_ENTITLEMENTS'] = 'MarketDecision.entitlements'
                else: settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'UI_TEST_HOST'
            with self.assertRaises(ValueError):
                result.validate_project(project)

    def test_direct_checker_failure_removes_old_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report.json'
            report.write_text('{"status":"PASS"}')
            with patch.object(sys, 'argv', ['checker', 'missing.xcresult', str(report), 'app']), patch.object(result, 'check_project', side_effect=ValueError('bad project')):
                with self.assertRaises(ValueError): result.main()
            self.assertFalse(report.exists())

    def test_missing_developer_directory_removes_old_pass_before_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'Scripts'; scripts.mkdir()
            script = scripts / 'verify-file-panels.sh'
            shutil.copy2(Path(__file__).with_name(script.name), script)
            report = root / '.build/validation/file-panel-report.json'
            report.parent.mkdir(parents=True); report.write_text('{"status":"PASS"}')
            environment = dict(os.environ); environment.pop('DEVELOPER_DIR', None)
            process = subprocess.run(['/bin/bash', str(script)], env=environment, capture_output=True)
            self.assertNotEqual(process.returncode, 0)
            self.assertFalse(report.exists())


if __name__ == '__main__':
    unittest.main()
