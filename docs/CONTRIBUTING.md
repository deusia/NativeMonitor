# 参与贡献

欢迎通过 [Issues](https://github.com/deusia/NativeMonitor/issues) 报告问题或讨论功能。较大的行为或架构调整请先说明使用场景，避免重复工作。

## 本地开发

需要 Apple Silicon Mac、Swift 6 工具链和包含 macOS 26 Glass API 的 Xcode SDK。构建方法见 [README](../README.md#构建与运行)，实际验证范围见[兼容性记录](compatibility.md)。

```sh
python3 scripts/check-version.py --self-test
python3 scripts/check-version.py
swift test
./build.sh
```

CI 通过 Xcode 工程运行同一套测试，使测试进程具有应用宿主；本地也可在 Xcode 中按 ⌘U 验证。

Swift 源码位于 `Sources/NativeMonitor`，私有背景接口封装位于 `Sources/PrivateBackdrop`，测试位于 `Tests/NativeMonitorTests`。

## 提交 PR

从最新 `main` 创建分支，通过 PR 合并；`main` 禁止直接推送和强推。保持改动聚焦，说明具体问题、结果和实际验证；修复复杂逻辑时补充有意义的回归测试，界面改动附截图。

指标口径和兼容性变化需同步文档。GPU、ANE、AppleSMC 和背景模糊涉及实验性或私有接口，不应把单机结果推广为所有机型通用；读取失败时保留不可用状态，不能用模拟数据或其他指标替代。CI 不等于真实硬件或完整界面验收。

贡献代码随项目采用 GPL-3.0-only。引用第三方代码、数据映射或资源时，请保留来源和适用的版权、许可声明，不提交密钥、私人日志或设备标识。

发布版本时参照[发布流程](releasing.md)。
