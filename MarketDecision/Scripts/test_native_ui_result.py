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

if __name__ == '__main__':
    unittest.main()
