#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to your Xcode app Contents/Developer directory}"
export DEVELOPER_DIR
xcodebuild -version
python3 "$project_root/Scripts/test_profile_time.py"
python3 "$project_root/Scripts/check-boundaries.py"
xcrun swift test --package-path "$project_root" --jobs 4
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme MarketDecision -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$project_root/DerivedData" -jobs 4 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
python3 "$project_root/Scripts/check-demo-entitlements.py" "$project_root/DerivedData/Build/Products/Debug/MarketDecision.app"
