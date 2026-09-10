#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set an explicitly selected Xcode developer directory}"
export DEVELOPER_DIR
export MARKETDECISION_TEST_KEYCHAIN=0
project_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(git -C "$project_root" rev-parse --show-toplevel)"
# This entry point is for the clean public checkout, never the private planning repository.
python3 "$project_root/Scripts/check-ci-inputs.py" "$repo_root"
xcodebuild -version
xcrun swift --version
sw_vers
uname -m
case "${1:-all}" in tests|builds|all) ;; *) echo 'Expected tests, builds or all' >&2; exit 2 ;; esac
if [[ "${1:-all}" != builds ]]; then
  python3 "$project_root/Scripts/test_profile_time.py"
  python3 "$project_root/Scripts/check-boundaries.py"
  python3 "$project_root/Scripts/test_foundation_traceability.py"
  python3 "$project_root/Scripts/run-foundation-tests.py"
  echo 'Keychain integration: NOT EXECUTED (default skip is not a pass)'
fi
if [[ "${1:-all}" != tests ]]; then
  for configuration in Debug Release; do
    xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme MarketDecision \
      -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$project_root/DerivedDataCI" -jobs 4 \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
      PROVISIONING_PROFILE_SPECIFIER= \
      CODE_SIGN_ENTITLEMENTS="$project_root/App/MarketDecision.entitlements" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
    app="$project_root/DerivedDataCI/Build/Products/$configuration/MarketDecision.app"
    python3 "$project_root/Scripts/check-demo-entitlements.py" "$app"
    if [[ "$configuration" == Release ]]; then
      python3 "$project_root/Scripts/check-release-isolation.py" "$app"
    fi
  done
fi
