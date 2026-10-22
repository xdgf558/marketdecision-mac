#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set an explicitly selected Xcode developer directory}"
export DEVELOPER_DIR
project_root="$(cd "$(dirname "$0")/.." && pwd)"
production_app="${1:?Pass the built production app}"
python3 "$project_root/Scripts/check-demo-entitlements.py" "$production_app"
xcrun swift build --package-path "$project_root" --product SECNetworkIsolationProbe --jobs 4
binary_path="$(xcrun swift build --package-path "$project_root" --show-bin-path)"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/sec-equity-ai-network-isolation.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
probe_app="$probe_root/MarketDecision.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/XPCServices"
cp "$binary_path/SECNetworkIsolationProbe" "$probe_app/Contents/MacOS/SECNetworkIsolationProbe"
# Copy actual built services; no test helper, broadened permission or global listener.
for service in SECNetworkService EquityNetworkService AIAnalysisNetworkService; do
  ditto "$production_app/Contents/XPCServices/$service.xpc" "$probe_app/Contents/XPCServices/$service.xpc"
done
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
# Preserve a pristine sealed wrapper for three independent tamper cases. Each nested helper
# remains validly signed, but changing it without re-signing the containing app must fail.
pristine_app="$probe_root/Pristine.app"
ditto "$probe_app" "$pristine_app"
tamper_failed=0
for service in SECNetworkService EquityNetworkService AIAnalysisNetworkService; do
  echo "CHECK: independent replacement fixture for $service"
  rm -rf "$probe_app"
  ditto "$pristine_app" "$probe_app"
  python3 - "$probe_app" "$service" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/XPCServices' / (sys.argv[2] + '.xpc') / 'Contents/Info.plist'
value = plistlib.loads(path.read_bytes())
value['SyntheticReplacementProbe'] = True
path.write_bytes(plistlib.dumps(value))
PY
  codesign --force --sign - --options runtime --entitlements "$project_root/App/$service.entitlements" \
    "$probe_app/Contents/XPCServices/$service.xpc"
  # Establish the fixture independently: a valid nested signature must violate the
  # unchanged containing seal. Never count a broken/unsigned helper as this rejection case.
  codesign --verify --strict "$probe_app/Contents/XPCServices/$service.xpc"
  if codesign --verify --deep --strict "$probe_app" > "$probe_root/outer-seal-check.log" 2>&1; then
    echo "FAIL: replacement fixture did not invalidate the containing app seal ($service)" >&2
    exit 1
  fi
  echo "PASS: replacement helper valid; containing app seal invalid ($service)"
  if ! "$probe_app/Contents/MacOS/SECNetworkIsolationProbe" --expect-invalid-broker "$service"; then
    tamper_failed=1
  fi
done
if [[ "$tamper_failed" != 0 ]]; then
  echo 'FAIL: one or more replacement fixtures were accepted by a broker' >&2
  exit 1
fi
# Synthetic process/IPC denial only: no valid provider requests, credentials, file panels,
# Apple Development signature, production workflow or performance acceptance.
