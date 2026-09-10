#!/usr/bin/env python3
"""Generate a fresh event stream and bind the accounting report to unchanged input bytes."""
from pathlib import Path
import json, os, subprocess, tempfile
from foundation_traceability import load_catalog, validate_catalog, validate_events, validate_log_boundary, input_hashes

root = Path(__file__).resolve().parents[1]
report = root / '.build/validation/trace-report.json'
report.parent.mkdir(parents=True, exist_ok=True)
report.unlink(missing_ok=True) # Never leave an old PASS report after a failed run.
expected = validate_catalog(root, load_catalog(root))
validate_log_boundary(root)
before = input_hashes(root)
env = dict(os.environ, MARKETDECISION_TEST_KEYCHAIN='0')
with tempfile.TemporaryDirectory(prefix='foundation-events-') as temporary:
    events = Path(temporary) / 'events.jsonl'
    subprocess.run(['xcrun', 'swift', 'test', '--package-path', str(root), '--jobs', '4',
                    '--event-stream-output-path', str(events), '--event-stream-version', '0'], env=env, check=True)
    result = validate_events([json.loads(line) for line in events.read_text().splitlines()], expected)
    if input_hashes(root) != before:
        raise SystemExit('FAIL: verification inputs changed during the test run')
    result.update({'scope': 'public foundation accounting, not semantic coverage or full acceptance', 'source_sha256': before})
    report.write_text(json.dumps(result, indent=2) + '\n')
print(f"PASS: public traceability accounts for {len(result['passed'])} executed tests; {len(result['not_executed'])} Keychain test NOT EXECUTED.")
