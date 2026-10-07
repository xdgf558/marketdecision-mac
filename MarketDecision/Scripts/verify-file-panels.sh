#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
report="$project_root/.build/validation/file-panel-report.json"
mkdir -p "$(dirname "$report")"
rm -f "$report"
: "${DEVELOPER_DIR:?Set an explicitly selected Xcode developer directory}"
export DEVELOPER_DIR
repo_root="$(git -C "$project_root" rev-parse --show-toplevel)"
python3 "$project_root/Scripts/check-ci-inputs.py" "$repo_root"
python3 "$project_root/Scripts/test_file_panel_result.py"
actual_os="$(sw_vers -productVersion)"
if [[ -n "${REQUIRE_UI_OS_MAJOR:-}" && "${actual_os%%.*}" != "$REQUIRE_UI_OS_MAJOR" ]]; then
  echo 'FAIL: file-panel runner OS differs from required major version' >&2
  exit 1
fi
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/marketdecision-file-panels.XXXXXX")"
python3 "$project_root/Scripts/check-file-panel-result.py" --inputs "$result_dir/inputs.json"
# Keep failed local xcresults available for diagnosis; never upload artifacts.
trap 'echo "Local file-panel result directory: $result_dir"' EXIT
host="$project_root/DerivedDataFilePanels/Build/Products/Release/MarketDecisionFileAcceptance.app"
xcodebuild -version
sw_vers
uname -m
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme ProductionFilePanelTests \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/DerivedDataFilePanels" -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES build
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme ProductionFilePanelTests \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/DerivedDataFilePanels" -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES build-for-testing
python3 "$project_root/Scripts/check-file-panel-result.py" --app-only "$host"
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme ProductionFilePanelTests \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/DerivedDataFilePanels" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 360 \
  -resultBundlePath "$result_dir/Results.xcresult" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES test-without-building
python3 "$project_root/Scripts/check-file-panel-result.py" --verify-inputs "$result_dir/inputs.json"
python3 "$project_root/Scripts/check-file-panel-result.py" "$result_dir/Results.xcresult" "$report" "$host"
echo 'File panels: production source and file-only Release permissions; no network, real data or Keychain acceptance.'
