#!/bin/bash
set -euo pipefail
: "${DEVELOPER_DIR:?Set the Xcode developer directory}"
: "${MARKETDECISION_SIGNING_TEAM:?Set your logged-in Apple development team ID}"
export DEVELOPER_DIR
project_root="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$project_root/App/MarketDecision.xcodeproj" -scheme MarketDecision \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$project_root/DerivedDataProvision" -jobs 4 \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' \
  DEVELOPMENT_TEAM="$MARKETDECISION_SIGNING_TEAM" \
  CODE_SIGN_ENTITLEMENTS="$project_root/App/MarketDecision-Signed.entitlements" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
python3 "$project_root/Scripts/check-demo-entitlements.py" \
  "$project_root/DerivedDataProvision/Build/Products/Debug/MarketDecision.app" --provisioned
