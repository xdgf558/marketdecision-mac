#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set an explicitly selected Xcode developer directory}"
export DEVELOPER_DIR
project_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(git -C "$project_root" rev-parse --show-toplevel)"
python3 "$project_root/Scripts/check-ci-inputs.py" "$repo_root"
python3 "$project_root/Scripts/test_native_ui_result.py"
actual_os="$(sw_vers -productVersion)"
if [[ -n "${REQUIRE_UI_OS_MAJOR:-}" && "${actual_os%%.*}" != "$REQUIRE_UI_OS_MAJOR" ]]; then
  echo 'FAIL: native UI runner OS differs from required major version' >&2
  exit 1
fi
report="$project_root/.build/validation/native-ui-report.json"
mkdir -p "$(dirname "$report")"
rm -f "$report"
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/marketdecision-native-ui.XXXXXX")"
trap 'rm -rf "$result_dir"' EXIT
xcodebuild -version
sw_vers
uname -m
host="$project_root/DerivedDataNativeUI/Build/Products/Debug/MarketDecisionUITestHost.app"
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme NativeInteractionTests \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/DerivedDataNativeUI" -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES build-for-testing
python3 "$project_root/Scripts/check-native-ui-result.py" --host-only "$host"
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme NativeInteractionTests \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/DerivedDataNativeUI" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 90 \
  -resultBundlePath "$result_dir/Results.xcresult" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES test-without-building
python3 "$project_root/Scripts/check-native-ui-result.py" "$result_dir/Results.xcresult" "$report" "$host"
echo 'Native UI: synthetic in-memory host only; Keychain, VoiceOver speech and real IME composition NOT EXECUTED.'
