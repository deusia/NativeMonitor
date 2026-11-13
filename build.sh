#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "此原型只面向 Apple Silicon，请在 arm64 Mac 上构建。" >&2
  exit 1
fi
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# 明确记录实际 SDK，避免当前链接流程将 SDK 版本写成最低部署版本。
swift build -c release --sdk "$sdk_path" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
app_path="$(pwd)/../NativeMonitor.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/NativeMonitor "$app_path/Contents/MacOS/NativeMonitor"
cp Assets/NativeMonitor.icns "$app_path/Contents/Resources/NativeMonitor.icns"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeMonitor</string>
<key>CFBundleIdentifier</key><string>local.ashen.NativeMonitorPrototype</string>
<key>CFBundleName</key><string>NativeMonitor</string>
<key>CFBundleIconFile</key><string>NativeMonitor</string>
<key>CFBundleDisplayName</key><string>性能监控原型</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"
printf '已构建：%s\n' "$app_path"
