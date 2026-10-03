#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
xcodebuild -project WiFiSync.xcodeproj -scheme WiFiSync -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
print '构建完成：.build/DerivedData/Build/Products/Debug/WiFiSync.app'
