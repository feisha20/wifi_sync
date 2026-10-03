#!/bin/zsh
# 构建发布版本，生成包含应用与“应用程序”入口的压缩安装镜像。
set -euo pipefail
cd "$(dirname "$0")/.."

zsh scripts/build.sh Release
app_path="$PWD/.build/DerivedData/Build/Products/Release/WiFiSync.app"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
mkdir -p dist
dmg_filename="相机素材同步-${app_version}-${app_build}-arm64.dmg"
dmg_path="$PWD/dist/$dmg_filename"
staging_path=$(mktemp -d "$PWD/.build/dmg-staging.XXXXXX")
trap 'rm -rf -- "$staging_path"' EXIT

codesign --verify --deep --strict "$app_path"
ditto "$app_path" "$staging_path/相机素材同步.app"
ln -s /Applications "$staging_path/Applications"
cat > "$staging_path/安装说明.txt" <<'EOF'
相机素材同步

适用环境：Apple 芯片 Mac，macOS 15 或更高版本。

安装步骤：
1. 完全退出正在运行的旧版本。
2. 将“相机素材同步.app”拖入旁边的 Applications（应用程序）文件夹。
3. 在“应用程序”文件夹打开“相机素材同步”。
4. 安装完成后推出此磁盘镜像。

这是供个人使用的本机签名版本，未进行 Apple 公证。
如系统拦截首次启动，请在“系统设置 → 隐私与安全性”中允许打开。
EOF
hdiutil create -volname '相机素材同步' -srcfolder "$staging_path" \
  -format UDZO -imagekey zlib-level=9 -ov "$dmg_path"
hdiutil verify "$dmg_path"
(
  cd dist
  shasum -a 256 "$dmg_filename" > "$dmg_filename.sha256"
)
print "打包完成：$dmg_path"
