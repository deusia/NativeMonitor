历史阶段记录：本文的实现、验证结果及“当前”描述仅适用于记录当时；现状请参阅 README.md。

# 背景材质与 SDK 链接调查

日期：2026-11-10。

## SDK 证据

- 本机 Xcode SDKSettings.json 与 xcrun --show-sdk-version 均为 27.2；Swift 6.4.2，ld 27106.1。没有安装或升级工具链。
- Package.swift 最低部署 macOS 14；原始 SwiftPM 使用默认 swiftbuild 引擎，manifest 的 swiftc 命令包含 -sdk MacOSX27.2.sdk 和 -target arm64-apple-macos14.0。
- Views.o 的 LC_BUILD_VERSION 为 minos 14.0 / sdk 27.2，而原应用最终 Mach-O 为 minos 14.0 / sdk 14.0。
- 重放原项目链接调用并启用 Clang verbose，实际 ld 参数为 -platform_version macos 14.0.0 14.0.0。证明版本在最终链接阶段变为 14，而不是没有使用新 SDK 编译。
- 相同工具链、相同 target/SDK 的独立最小 Swift 程序及单独对象链接记录 sdk 27.2。重放项目输入仍为 14.0；排除了简单移除 reproducible、dead_strip、emit-executable、link-objc-runtime、no-stdlib-rpath 的修复。更深层驱动决策原因尚未定位，不能直接归咎整个 SwiftPM 或 ld。
- 最小修正：build.sh 从 xcrun 获取当前 SDK 路径/版本，显式传入 -platform_version macos 14.0 <实际SDK版本>。重新构建后的应用确认为 minos 14.0 / sdk 27.2，保留最低部署版本。没有对二进制事后篡改版本。
- 既有 macOS 26 availability guard 保留；新系统玻璃 API 原先即编译并运行。未做仅切换 SDK 元数据、其他条件完全相同的材质 A/B 实验，因此不认定 SDK 标记是原视觉差距原因。

## 公共 API 与外观修订

Apple 说明 NSVisualEffectView 可对窗口后方内容提供半透明、模糊和 vibrancy；材质外观受系统设置、外观与 emphasized 状态影响，不公开承诺控制中心内部算法或固定模糊半径。

- https://developer.apple.com/documentation/appkit/nsvisualeffectview
- https://developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage
- https://developer.apple.com/design/human-interface-guidelines/materials

最终仍是一个整体 behindWindow HUD 底板，覆盖卡片/侧栏间隙。移除外层 glassEffect 轮廓、硬圆角裁剪及详情窗口阴影，关闭 emphasized。使用公开 maskImage，让底板四边 24 pt 渐退；65×65 小蒙版通过 capInsets 拉伸，不随 GPU 更新重画。前景没有套模糊。

尝试 underWindowBackground 后实机灰实、颜色损失明显，因此已放弃；native-soft-overview.png / native-soft-detail.png 为该中间实验，不是最终材质。

最终 native-feathered-detail.png 为桌面区域合成截图，可见壁纸色彩穿透和四边渐退，前景可读。仍有可感知的宽渐变区域，并非完全无边；截图左下有其他浮层干扰，不用它声称整幅完全验收。概览在抓图时被用户切换，最终 HUD 概览未完成独立截图复验，不重复扰动用户。

## 验证与边界

- 最新 swift test：9 项通过，包含蒙版中心不透明、边缘透明、向内递增及左右对称检查。
- release 构建成功，无编译警告；最终 arm64 / minos14.0 / sdk27.2；本地签名与 ZIP 完整性通过。
- 中间柔边版实际点击概览 GPU 卡进入详情，实测值和时间继续更新。最终 HUD 版运行并观察到实测 GPU 对照值变化。
- 此次没有重新逐项验收全部快捷键、快速动画开关、深色、减少透明度、跨屏、旧系统、VoiceOver或长时间资源开销。
- 公共材质与蒙版只能做受窗口范围限制的近似；不承诺控制中心的无边界可变模糊、私有合成行为或像素等同。
