#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_root/DerivedDataProvision/Build/Products/Debug/MarketDecision.app"
python3 "$project_root/Scripts/check-demo-entitlements.py" "$app" --provisioned
run_id="$(uuidgen)"
exe="$app/Contents/MacOS/MarketDecision"
# Each invocation must exit successfully before the next process starts.
# Keep the random identifier available for cleanup if an invocation fails.
echo "Synthetic diagnostic run: $run_id"
run_probe() {
  python3 - "$exe" "$1" "$run_id" <<'PYRUN'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1], '--keychain-diagnostic', sys.argv[2], sys.argv[3]], timeout=30)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    raise SystemExit('FAIL: app diagnostic timed out')
PYRUN
}
cleanup() {
  run_probe cleanup || {
    echo "FAIL cleanup; rerun diagnostic cleanup with the run identifier above" >&2
    return 1
  }
}
trap 'cleanup || exit 1' EXIT
run_probe create
run_probe resume
run_probe absent
