"""Fail before test/build commands if private planning or signing files are tracked."""
from pathlib import Path, PurePosixPath
import subprocess
import sys

root = Path(sys.argv[1])
files = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
for name in filter(None, files):
    path = PurePosixPath(name)
    forbidden = (path.parts[0] == 'Documentation' or path.name in {'AGENTS.md', 'design-qa.md'}
                 or path.suffix.lower() in {'.p12', '.pfx', '.pem', '.key', '.mobileprovision', '.provisionprofile', '.sqlite', '.db', '.log'}
                 or path.name == '.env' or path.name.startswith('.env.'))
    if forbidden:
        raise SystemExit('FAIL: private planning, data or signing material in CI input')
print('PASS: tracked-file boundary check (not a full secret scanner)')
