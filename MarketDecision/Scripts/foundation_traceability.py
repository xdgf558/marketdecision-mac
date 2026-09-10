"""Public source/test accounting, not semantic code coverage or private acceptance."""
from pathlib import Path, PurePosixPath
import hashlib, json, re

class TraceError(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise TraceError(message)

def source_inventory(root):
    return {str(p.relative_to(root)) for folder in ['Sources', 'App', 'Tools']
            for p in (root / folder).rglob('*.swift')}

def safe_file(root, name):
    p = PurePosixPath(name)
    require(not p.is_absolute() and '..' not in p.parts and str(p) == name, 'Invalid relative path')
    path = root / name
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()), 'Missing or unsafe source')
    return path

def validate_catalog(root, catalog):
    require(catalog.get('version') == 1, 'Unsupported catalog version')
    sources, tests = catalog['sources'], catalog['tests']
    require(len({s['path'] for s in sources}) == len(sources), 'Duplicate source mapping')
    require({s['path'] for s in sources} == source_inventory(root), 'Source inventory differs from catalog')
    selectors = {t['selector'] for t in tests}
    require(len(selectors) == len(tests) and bool(tests), 'Duplicate or empty test mapping')
    conditional = 'FoundationTests.CredentialIntegrationTests/temporaryCredentialRoundTrip()'
    for test in tests:
        require(test['source'].startswith('Tests/FoundationTests/') and test['source'].endswith('.swift'), 'Invalid test source')
        safe_file(root, test['source'])
        require(test['execution'] in ['required', 'not_executed'], 'Invalid execution policy')
        require((test['selector'] == conditional) == (test['execution'] == 'not_executed'), 'Only the known Keychain test may be skipped')
    linked = set()
    for source in sources:
        safe_file(root, source['path'])
        require(source['kind'] in ['tested', 'build_only', 'shell'], 'Invalid source scope')
        require(bool(source['reason'].strip()), 'Missing scope explanation')
        suites = source['suites']
        known_suites = {selector.split('/')[0] for selector in selectors}
        require(set(suites) <= known_suites and len(set(suites)) == len(suites), 'Unknown or duplicate test suite reference')
        refs = {selector for selector in selectors if selector.split('/')[0] in suites}
        require(source['kind'] != 'tested' or bool(refs), 'Tested source has no tests')
        require(source['kind'] != 'shell' or not refs, 'Module shell must not claim tests')
        linked.update(refs)
    require(linked == selectors, 'Unlinked test declaration')
    return {t['selector']: t for t in tests}

def validate_log_boundary(root):
    # Deliberately limited source guard, not a Swift parser or full taint/secret scanner.
    sinks = re.compile(r'\b(?:Logger|OSLog|NSLog|os_log|print|debugPrint|dump|fputs)\s*\(|FileHandle\.standard(?:Output|Error)')
    raw_error = re.compile(r'\.localizedDescription\b|String\s*\(\s*(?:describing|reflecting)\s*:\s*error\b')
    for name in source_inventory(root):
        if name.startswith('Tools/'):
            continue # Test-only codec writes its synthetic fixture to stdout; not in the application.
        text = safe_file(root, name).read_text()
        require(not raw_error.search(text), 'Raw error formatting enters application source: ' + name)
        if name not in ['Sources/Security/SafeLog.swift', 'App/KeychainDiagnostic.swift']:
            require(not sinks.search(text), 'Unreviewed output API in application source: ' + name)
    diagnostic = safe_file(root, 'App/KeychainDiagnostic.swift').read_text()
    # The exception is the already-reviewed Debug-only synthetic diagnostic, pinned in full.
    require(hashlib.sha256(diagnostic.encode()).hexdigest() == 'e64fb73ab4ea5f1f984de8bfbeafe36f2fe78f569b9f4eefe6dd184a81b207c6', 'Diagnostic output exception changed; review the boundary')

def validate_events(records, expected):
    declarations, events = {}, []
    for record in records:
        require(record.get('version') == 0, 'Unsupported Swift Testing event version')
        payload = record['payload']
        if record['kind'] == 'test':
            require(payload['id'] not in declarations, 'Duplicate test declaration')
            declarations[payload['id']] = payload
        elif record['kind'] == 'event':
            events.append(payload)
        else:
            raise TraceError('Unknown event record')
    kinds = [e['kind'] for e in events]
    require(bool(events) and kinds[0] == 'runStarted' and kinds[-1] == 'runEnded', 'Incomplete test run')
    require(kinds.count('runStarted') == kinds.count('runEnded') == 1, 'Mixed or duplicate runs')
    allowed = {'runStarted', 'runEnded', 'testStarted', 'testEnded', 'testSkipped', 'testCaseStarted', 'testCaseEnded'}
    require(set(kinds) <= allowed, 'Issue or unsupported event in test run')
    actual = {}
    for identity, test in declarations.items():
        if test['kind'] == 'suite':
            continue
        require(test['kind'] == 'function', 'Unknown test kind')
        selector = identity.rsplit('/', 1)[0]
        require(selector in expected and selector not in actual, 'Unexpected or duplicate function')
        file_id = test['sourceLocation']['fileID']
        require(file_id == 'FoundationTests/' + Path(expected[selector]['source']).name, 'Test source mismatch')
        actual[selector] = identity
    require(set(actual) == set(expected), 'Declared tests differ from fixed catalog')
    states = {key: [] for key in declarations}
    for event in events[1:-1]:
        require(event.get('testID') in declarations, 'Event references unknown test')
        states[event['testID']].append(event)
    passed, skipped = [], []
    for selector, identity in actual.items():
        test_events = states[identity]; names = [e['kind'] for e in test_events]
        if expected[selector]['execution'] == 'not_executed':
            require(names == ['testSkipped'], 'Conditional Keychain must remain NOT EXECUTED')
            skipped.append(selector); continue
        require(names.count('testStarted') == names.count('testEnded') == 1 and names[0] == 'testStarted' and names[-1] == 'testEnded' and 'testSkipped' not in names, 'Required test not fully executed')
        starts = [e['_testCase']['id'] for e in test_events if e['kind'] == 'testCaseStarted']
        ends = [e['_testCase']['id'] for e in test_events if e['kind'] == 'testCaseEnded']
        require(len(set(starts)) == len(starts) and sorted(starts) == sorted(ends), 'Incomplete or duplicate parameter cases: ' + selector)
        for case in starts:
            start_at = next(i for i, e in enumerate(test_events) if e['kind'] == 'testCaseStarted' and e['_testCase']['id'] == case)
            end_at = next(i for i, e in enumerate(test_events) if e['kind'] == 'testCaseEnded' and e['_testCase']['id'] == case)
            require(start_at < end_at, 'Parameter case ended before it started')
        if declarations[identity].get('isParameterized'):
            require(bool(starts), 'Parameterized test executed zero cases')
        passed.append(selector)
    return {'passed': sorted(passed), 'not_executed': sorted(skipped)}

def input_hashes(root):
    paths = set(source_inventory(root))
    for folder in ['Tests', 'Scripts', 'Validation']:
        paths.update(str(p.relative_to(root)) for p in (root / folder).rglob('*')
                     if p.is_file() and p.suffix in ['.swift', '.py', '.json', '.sh'])
    paths.update(['Package.swift', 'Package.resolved', 'App/MarketDecision.xcodeproj/project.pbxproj', 'App/MarketDecision.entitlements'])
    return {name: hashlib.sha256(safe_file(root, name).read_bytes()).hexdigest() for name in sorted(paths)}

def load_catalog(root):
    return json.loads((root / 'Validation/source-tests.json').read_text())
