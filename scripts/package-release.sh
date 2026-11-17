#!/bin/bash
# 从已提交的源码构建发布包，同时保留对应源码与 GPL 许可证。
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo "请先提交或清理工作区，再打包，以保证产物与对应源码一致。" >&2
  exit 1
fi
python3 scripts/check-version.py
version="$(cat VERSION)"
./build.sh
codesign --verify --deep --strict ../NativeMonitor.app
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../NativeMonitor.app/Contents/Info.plist)"
[[ "$actual_version" == "$version" ]] || { echo "产物版本不一致" >&2; exit 1; }
output="$(pwd)/.build/release-artifacts/$version"
mkdir -p "$output"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
package="NativeMonitor-$version"
mkdir "$stage/$package"
ditto ../NativeMonitor.app "$stage/$package/NativeMonitor.app"
cp LICENSE README.md CONTRIBUTING.md "$stage/$package/"
ditto docs "$stage/$package/docs"
git rev-parse HEAD > "$stage/$package/SOURCE.txt"
printf '对应源码：https://github.com/deusia/NativeMonitor/tree/%s\n' "$(git rev-parse HEAD)" >> "$stage/$package/SOURCE.txt"
ditto -c -k --sequesterRsrc --keepParent "$stage/$package" "$output/$package-macos-arm64.zip"
git archive --format=tar.gz --prefix="$package-source/" -o "$output/$package-source.tar.gz" HEAD
cd "$output"
shasum -a 256 "$package-macos-arm64.zip" "$package-source.tar.gz" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
printf '发布文件：%s\n' "$output"
