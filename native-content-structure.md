# 玻璃内容层候选 · 2026-11-10 11:43

状态：结构优化与同窗口采样对照通过；控制中心同款视觉和展开动画尚未完成。

## 官方依据

- https://developer.apple.com/videos/play/wwdc2025/310/ （17:30 起）：NSGlassEffectView 应通过 contentView 承载前景；相邻玻璃容器统一采样和形变，并不保证填充所有间隙。
- https://developer.apple.com/videos/play/wwdc2025/219/ ：玻璃出现/消失涉及 lensing 调制，普通 alpha 渐变不等同于该行为。

## 本轮实现

- 删除独立 NSPanel 玻璃背景、双窗口尺寸/透明度/外观同步逻辑。
- 概览和详情改为 SwiftUI 内容自身应用 glassEffect；仍由原 NSHostingController 管理，工具栏没有迁移到自制控制器。
- 玻璃外留 32pt 柔边空间，前景落在蒙版全不透明范围内。详情最小尺寸相应增加 64pt。
- 应用或系统减少透明度时，使用 Glass.identity 和实色背景，保留尺寸一致性；旧系统保留原材质路径。
- GPU、其他模拟指标、采样来源不变。当前窗口开关仍是原有缩放与 alpha 过渡，没有冒称原生 lensing，也没有实现 NSPopover 替换。

## 实际验证

- swift test：10 项、0 失败。替换了已删除双窗口结构的测试，覆盖柔边蒙版及透明/实色两态 fittingSize 一致。
- release 构建通过，无编译警告。
- 实际观察到主程序详情及三项原生工具栏、实时 GPU 读数。较早同轮构建完成 GPU 卡片导航；最终构建复验期间出现多次外部状态改变，不能把未完成的点击序列算作通过。
- 对照程序直接复用最终 Overview/Views/Model/GPU 源码，在同一窗口绘制彩条、细字和横线。native-content-calibration-cua.png 为 CUA 完整合成截图：中间内容与间隙背景文字柔化、左右裸背景保持清晰、前景文字清晰、外围渐变。
- 同一窗口的单窗口截图导出丢失部分效果，与 CUA 完整合成结果不同；不把该导出当作最终屏幕证据。真实桌面采样仍需另行验收。
- 实际切换减少透明度：实色回退生效，但设置浮层仍收起，该交互限制未解决。

## 已否定的尝试

- NSHostingController.loadView 包装实验没有实际生效，层级断言捕获，未交付。
- 显式替换 NSHostingController.view 后，fittingSize 在 SwiftUI 环境更新中卡住；取样记录在 work/contentview-probe/test-hang.txt。已撤销此方案并结束测试进程。

## 边界

当前同窗口模糊比控制中心参考更强，颜色也更淡；没有宣称已达到目标。未检查跨屏、全部暗色背景、长期功耗与旧版 macOS。未使用私有 API、录屏贴图或截图作为应用背景。
