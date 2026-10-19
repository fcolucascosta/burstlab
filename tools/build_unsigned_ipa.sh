#!/bin/bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_root/build/ios-device"
mkdir -p "$build_dir" "$project_root/build/dist"

xcodebuild \
  -project "$project_root/BurstLab.xcodeproj" \
  -scheme BurstLab-iOS \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

python3 "$project_root/tools/package_ipa.py" \
  "$build_dir/DerivedData/Build/Products/Release-iphoneos/BurstLab-iOS.app"
