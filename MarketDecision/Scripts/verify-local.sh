#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27-beta-6.app/Contents/Developer}"
xcodebuild -version
python3 "$project_root/Scripts/test_profile_time.py"
python3 "$project_root/Scripts/check-boundaries.py"
python3 "$project_root/Scripts/test_foundation_traceability.py"
python3 "$project_root/Scripts/run-foundation-tests.py"
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme MarketDecision -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$project_root/DerivedData" -jobs 4 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
python3 "$project_root/Scripts/check-demo-entitlements.py" "$project_root/DerivedData/Build/Products/Debug/MarketDecision.app"
