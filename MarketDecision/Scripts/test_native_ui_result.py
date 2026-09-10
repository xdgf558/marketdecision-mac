"""Mutation checks for native result accounting, not UI execution."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('native_result', Path(__file__).with_name('check-native-ui-result.py'))
result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(result)

class NativeResultTests(unittest.TestCase):
    def setUp(self):
        self.summary = dict(totalTestCount=4, passedTests=4, failedTests=0, skippedTests=0)
        self.tree = {'testNodes': [{'name': n + '()', 'result': 'Passed'} for n in sorted(result.expected)]}
    def rejected(self, summary=None, tree=None):
        with self.assertRaises(ValueError):
            result.validate_results(self.summary if summary is None else summary, self.tree if tree is None else tree)
    def test_exact_four_pass(self):
        self.assertEqual(set(result.validate_results(self.summary, self.tree)), result.expected)
    def test_skip_is_not_pass(self):
        self.summary.update(skippedTests=1, passedTests=3); self.rejected()
    def test_failure_is_not_pass(self):
        self.summary.update(failedTests=1); self.rejected()
    def test_incomplete_or_unknown_summary(self):
        self.rejected({}); self.summary.update(totalTestCount=0); self.rejected()
    def test_missing_or_wrong_identity(self):
        self.tree['testNodes'][0]['name'] = 'someOtherTest()'; self.rejected()
    def test_duplicate_identity(self):
        self.tree['testNodes'].append(copy.deepcopy(self.tree['testNodes'][0])); self.rejected()
    def test_terminal_status_must_pass(self):
        self.tree['testNodes'][0]['result'] = 'Skipped'; self.rejected()

class NativeHostPermissionTests(unittest.TestCase):
    def setUp(self):
        self.identity = 'local.marketdecision.ui-test-host'
        self.entitlements = {
            'com.apple.security.app-sandbox': True,
            'com.apple.security.get-task-allow': True,
            'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/'],
            'com.apple.security.temporary-exception.mach-lookup.global-name': [
                'com.apple.testmanagerd', 'com.apple.dt.testmanagerd.runner', 'com.apple.coresymbolicationd'],
        }
    def rejected(self):
        with self.assertRaises(ValueError):
            result.validate_host_entitlements(self.identity, self.entitlements)
    def test_exact_test_host_only(self):
        result.validate_host_entitlements(self.identity, self.entitlements)
        self.identity = 'local.marketdecision.development'; self.rejected()
    def test_network_or_write_permission_rejected(self):
        for key in ['com.apple.security.network.client', 'com.apple.security.temporary-exception.files.absolute-path.read-write']:
            self.entitlements[key] = True; self.rejected(); del self.entitlements[key]
    def test_sandbox_must_be_boolean_true(self):
        for value in [False, 1, 'true', None]:
            self.entitlements['com.apple.security.app-sandbox'] = value; self.rejected()
    def test_changed_or_missing_read_scope_rejected(self):
        key = 'com.apple.security.temporary-exception.files.absolute-path.read-only'
        self.entitlements[key] = ['/tmp/']; self.rejected()
        del self.entitlements[key]; self.rejected()
    def test_unknown_or_duplicate_service_rejected(self):
        key = 'com.apple.security.temporary-exception.mach-lookup.global-name'
        self.entitlements[key].append('other.service'); self.rejected()
        self.entitlements[key] = ['com.apple.testmanagerd'] * 3; self.rejected()

if __name__ == '__main__':
    unittest.main()
