#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set an explicitly selected Xcode developer directory}"
export DEVELOPER_DIR
project_root="$(cd "$(dirname "$0")/.." && pwd)"
production_app="${1:?Pass the built production app}"
python3 "$project_root/Scripts/check-demo-entitlements.py" "$production_app"
xcrun swift build --package-path "$project_root" --product SECNetworkIsolationProbe --jobs 4
binary_path="$(xcrun swift build --package-path "$project_root" --show-bin-path)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/sec-network-isolation.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
probe_app="$probe_root/MarketDecision.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/XPCServices"
cp "$binary_path/SECNetworkIsolationProbe" "$probe_app/Contents/MacOS/SECNetworkIsolationProbe"
# Run the actual built service, not a test service with relaxed permissions or authentication.
ditto "$production_app/Contents/XPCServices/SECNetworkService.xpc" "$probe_app/Contents/XPCServices/SECNetworkService.xpc"
python3 - "$probe_app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.marketdecision.development',
    'CFBundleExecutable': 'SECNetworkIsolationProbe',
    'CFBundleName': 'SECNetworkIsolationProbe', 'CFBundlePackageType': 'APPL',
    'LSBackgroundOnly': True,
}))
PY
codesign --force --sign - --options runtime --entitlements "$project_root/App/MarketDecision.entitlements" "$probe_app"
python3 "$project_root/Scripts/check-demo-entitlements.py" "$probe_app"
"$probe_app/Contents/MacOS/SECNetworkIsolationProbe"
# A helper can be validly signed on its own and still be an unauthorized replacement.
# Change and re-sign only that nested bundle; the containing app's seal must reject it.
python3 - "$probe_app" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/XPCServices/SECNetworkService.xpc/Contents/Info.plist'
value = plistlib.loads(path.read_bytes())
value['SyntheticReplacementProbe'] = True
path.write_bytes(plistlib.dumps(value))
PY
codesign --force --sign - --options runtime --entitlements "$project_root/App/SECNetworkService.entitlements" \
  "$probe_app/Contents/XPCServices/SECNetworkService.xpc"
"$probe_app/Contents/MacOS/SECNetworkIsolationProbe" --expect-invalid-broker
# This is an isolated synthetic process/IPC denial check, not an SEC download, native page,
# Apple Development signature, production workflow, or performance acceptance.
