import copy, json, tempfile, unittest
from pathlib import Path
from foundation_traceability import TraceError, validate_events, validate_catalog, validate_log_boundary, input_hashes, load_catalog

TEST = 'FoundationTests.ExampleTests/example()'
SKIP = 'FoundationTests.CredentialIntegrationTests/temporaryCredentialRoundTrip()'
def records(parameterized=False):
    def test(selector, name):
        return {'version': 0, 'kind': 'test', 'payload': {'id': selector + '/Example.swift:1:1', 'kind': 'function', 'isParameterized': parameterized and selector == TEST, 'sourceLocation': {'fileID': 'FoundationTests/' + name}}}
    def event(kind, selector=None, case=None):
        payload = {'kind': kind}
        if selector: payload['testID'] = selector + '/Example.swift:1:1'
        if case: payload['_testCase'] = {'id': case}
        return {'version': 0, 'kind': 'event', 'payload': payload}
    xs = [test(TEST, 'Example.swift'), test(SKIP, 'Keychain.swift'), event('runStarted'), event('testStarted', TEST)]
    if parameterized: xs += [event('testCaseStarted', TEST, 'a'), event('testCaseEnded', TEST, 'a')]
    return xs + [event('testEnded', TEST), event('testSkipped', SKIP), event('runEnded')]

EXPECTED = {TEST: {'source': 'Tests/FoundationTests/Example.swift', 'execution': 'required'},
            SKIP: {'source': 'Tests/FoundationTests/Keychain.swift', 'execution': 'not_executed'}}

class EventAccountingTests(unittest.TestCase):
    def test_distinguishes_execution_from_conditional_skip(self):
        result = validate_events(records(True), EXPECTED)
        self.assertEqual(result, {'passed': [TEST], 'not_executed': [SKIP]})
    def test_empty_truncated_and_mixed_runs_fail(self):
        for xs in [[], records()[:-1], records()+records(), records()[2:]]:
            with self.subTest(length=len(xs)), self.assertRaises(TraceError): validate_events(xs, EXPECTED)
    def test_required_test_cannot_be_removed_skipped_or_only_declared(self):
        for mode in ['remove', 'skip', 'unexecuted']:
            xs = records()
            if mode == 'remove': xs = [x for x in xs if x.get('payload', {}).get('id', '').split('/Example')[0] != TEST]
            elif mode == 'skip': xs[3]['payload']['kind'] = 'testSkipped'
            else: xs = xs[:3]+xs[5:]
            with self.subTest(mode=mode), self.assertRaises(TraceError): validate_events(xs, EXPECTED)
    def test_conditional_skip_is_not_counted_as_success(self):
        xs = records(); xs[-2]['payload']['kind'] = 'testEnded'
        with self.assertRaises(TraceError): validate_events(xs, EXPECTED)
    def test_issue_unknown_schema_and_unknown_test_fail(self):
        for mode in ['issue', 'version', 'identity', 'source']:
            xs = records()
            if mode == 'issue': xs.insert(-1, {'version': 0, 'kind': 'event', 'payload': {'kind': 'issueRecorded'}})
            elif mode == 'version': xs[0]['version'] = 1
            elif mode == 'identity': xs[0]['payload']['id'] = 'unexpected/Example.swift:1:1'
            else: xs[0]['payload']['sourceLocation']['fileID'] = 'FoundationTests/Other.swift'
            with self.subTest(mode=mode), self.assertRaises(TraceError): validate_events(xs, EXPECTED)
    def test_parameterized_test_needs_complete_nonempty_cases(self):
        for mode in ['empty', 'missing_end', 'reversed']:
            xs = records(True)
            if mode == 'empty': xs = xs[:4]+xs[6:]
            elif mode == 'missing_end': del xs[5]
            else: xs[4], xs[5] = xs[5], xs[4]
            with self.subTest(mode=mode), self.assertRaises(TraceError): validate_events(xs, EXPECTED)

class SourceAccountingTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(); self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.original = Path(__file__).resolve().parents[1]
        self.catalog = load_catalog(self.original)
        # Tiny synthetic files preserve only the paths needed for mutation tests.
        for name in {s['path'] for s in self.catalog['sources']} | {t['source'] for t in self.catalog['tests']}:
            path=self.root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('// fixture\n')
        diagnostic='App/KeychainDiagnostic.swift'
        (self.root/diagnostic).write_bytes((self.original/diagnostic).read_bytes())
    def test_missing_source_unmapped_source_and_missing_test_file_fail(self):
        validate_catalog(self.root, self.catalog)
        target=self.root/'Sources/New.swift'; target.write_text('// fixture')
        with self.assertRaises(TraceError): validate_catalog(self.root, self.catalog)
        target.unlink(); (self.root/self.catalog['sources'][0]['path']).unlink()
        with self.assertRaises(TraceError): validate_catalog(self.root, self.catalog)
        (self.root/self.catalog['sources'][0]['path']).write_text('// fixture')
        (self.root/self.catalog['tests'][0]['source']).unlink()
        with self.assertRaises(TraceError): validate_catalog(self.root, self.catalog)
    def test_duplicate_missing_links_and_skipped_required_test_fail(self):
        for mode in ['duplicate', 'links', 'skip', 'traversal']:
            catalog=copy.deepcopy(self.catalog)
            if mode=='duplicate': catalog['tests'].append(catalog['tests'][0])
            elif mode=='links':
                for source in catalog['sources']: source['suites']=[]
            elif mode=='skip': catalog['tests'][0]['execution']='not_executed'
            else: catalog['tests'][0]['source']='../outside.swift'
            with self.subTest(mode=mode), self.assertRaises(TraceError): validate_catalog(self.root,catalog)
    def test_direct_logging_raw_error_formatting_and_changed_diagnostic_fail(self):
        target=self.root/'Sources/Unsafe.swift'
        for code in ['print(secret)', 'Logger(subsystem: secret, category: secret)', 'message = error.localizedDescription', 'FileHandle.standardError.write(secret)']:
            target.write_text(code)
            with self.subTest(code=code), self.assertRaises(TraceError): validate_log_boundary(self.root)
        target.unlink(); validate_log_boundary(self.root)
        (self.root/'App/KeychainDiagnostic.swift').write_text('print(secret)')
        with self.assertRaises(TraceError): validate_log_boundary(self.root)
    def test_real_input_fingerprints_change_when_source_changes(self):
        for name in ['Package.swift','Package.resolved','App/MarketDecision.xcodeproj/project.pbxproj','App/MarketDecision.entitlements']:
            path=self.root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('fixture')
        before=input_hashes(self.root)
        (self.root/self.catalog['sources'][0]['path']).write_text('// changed')
        self.assertNotEqual(before,input_hashes(self.root))

if __name__ == '__main__': unittest.main()
