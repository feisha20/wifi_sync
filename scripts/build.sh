#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
build_configuration="${1:-Debug}"
case "$build_configuration" in
  Debug|Release) ;;
  *) print -u2 '构建配置必须为 Debug 或 Release'; exit 1 ;;
esac
mkdir -p .build
xcodebuild -project WiFiSync.xcodeproj -scheme WiFiSync -configuration "$build_configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
print "构建完成：.build/DerivedData/Build/Products/$build_configuration/WiFiSync.app"
