# 发布流程

使用 [SemVer](https://semver.org/lang/zh-CN/) 的 `X.Y.Z` 版本号。`0.y.z` 阶段不承诺稳定接口；已发布版本不得替换内容，有修改时发布新版本。

## 准备版本

1. 从最新 `main` 创建发布分支。
2. 更新根目录 `VERSION` 及 Xcode 工程 Debug、Release 的 `MARKETING_VERSION`。`build.sh` 从 `VERSION` 读取版本，校验脚本会拒绝格式错误或不一致。
3. 同一版本的重建若需要区分，更新 `build.sh` 的 `CFBundleVersion` 和 Xcode 的 `CURRENT_PROJECT_VERSION`；新发布版本默认构建号为 1。
4. 执行下列检查，通过 PR 合并，等待 CI 成功。涉及 UI 或采集逻辑时还需实机验收，并记录未覆盖范围。

```sh
python3 scripts/check-version.py --self-test
python3 scripts/check-version.py
swift test
./build.sh
```

## 打包与发布

在干净的、已合并的 `main` 工作区执行：

```sh
./scripts/package-release.sh
```

脚本重新构建并验证签名与版本，在 `.build/release-artifacts/<版本>/` 生成安装 ZIP、对应提交的源码压缩包和 `SHA256SUMS.txt`。安装包附带 GPL 许可证、README 和源码提交链接。CI 使用同一脚本生成供检查的构建产物，不会自动公开发布。

确认产物、安装和启动行为后，创建对应版本标签并发布。例如（将版本号替换为本次实际值，已存在的标签不得覆盖）：

```sh
version="$(cat VERSION)"
git tag -a "v$version" -m "发布 $version"
git push origin "v$version"
# 先编写发布说明，包含功能、兼容性、验证结果与签名状态。
gh release create "v$version" \
  ".build/release-artifacts/$version/NativeMonitor-$version-macos-arm64.zip" \
  ".build/release-artifacts/$version/NativeMonitor-$version-source.tar.gz" \
  ".build/release-artifacts/$version/SHA256SUMS.txt" \
  --verify-tag --title "NativeMonitor $version" --notes-file /tmp/release-notes.md
```

发布后检查附件上传状态及 SHA-256。没有 Developer ID 签名和 Apple 公证时，必须明确说明首次打开可能被 macOS 阻止，不将本地 ad-hoc 签名称为 Apple 认可的分发签名。
