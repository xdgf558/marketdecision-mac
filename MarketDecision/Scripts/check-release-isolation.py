"""Check shipped Mach-O images, not only the source compilation conditions."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
if entitlements.get('com.apple.security.get-task-allow', False):
    raise SystemExit('FAIL: Release allows debugger attachment')
markers = [b'--keychain-diagnostic', b'KeychainDiagnostic', b'local.marketdecision.app-diagnostic.', b'PASS app restart/']
images = []
for folder in [app / 'Contents/MacOS', app / 'Contents/Frameworks']:
    if folder.exists():
        for path in folder.rglob('*'):
            if path.is_file() and 'Mach-O' in subprocess.check_output(['file', '-b', str(path)], text=True):
                images.append(path)
                data = path.read_bytes()
                if any(marker in data for marker in markers):
                    raise SystemExit('FAIL: diagnostic marker in Release image ' + path.name)
if not images:
    raise SystemExit('FAIL: no Release Mach-O images inspected')
print('PASS: Release diagnostic markers absent; get-task-allow disabled; images=' + str(len(images)))
