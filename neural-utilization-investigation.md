# 神经加速器实时占用调研

2026-11-13，在 Apple M5 Max、macOS 27.3 和 Xcode / Instruments 27.2 上验证。以下结果仅适用于这台机器及本次测试，不代表其他版本的系统行为。

## GPU Neural Accelerator

- Apple 的 [Metal System Trace 演示](https://developer.apple.com/videos/play/tech-talks/111432/)使用 `Performance Limiters` 计数器组展示 Neural Accelerator 利用率；该硬件位于 GPU 核心中，与独立的 Apple Neural Engine 不同。
- 本机 Metal `MTLDevice.counterSets` 仅列出 `timestamp`，不能据此获取神经加速器占用。
- `xctrace record --template 'Metal System Trace' --all-processes --time-limit 5s --no-prompt` 可以完成录制。默认计数器组为 `None`，导出的计数器信息只有 `RT Unit Active`，没有目标指标。
- 在 Instruments 图形界面选择 `Performance Limiters` 和即时处理后，GPU Counters 轨道没有结果；跟踪报告多条 `Cannot find GPU device for counter values` 和 `Cannot find GPU device for shader profiler values`。目前未确定具体原因。
- 录制进行时尝试 `xctrace export --toc` 返回 `Document Missing Template Error`。短时全系统跟踪会产生较大的临时文件和处理开销，因此本次没有找到可直接用作菜单栏秒级数据源的可靠路径。不能由这一实验断言其他版本的 Instruments 无法实时显示计数器。

## 独立 Apple Neural Engine

- [aneperf](https://github.com/tmc/aneperf) 描述了通过私有 `libIOReport` 的 `Fast-Die CE` 百分比分桶计算估算值的方案；它不是 Apple 公布的稳定监控契约。
- 本机可在 `PMP0 / Fast-Die CE / ANE0` 发现 21 个 0%–100% 分桶。对该组进行连续两秒差分采样时，所有桶均为零；并行执行受控 Core ML 测试时也没有获得有效增量。相同采样机制读取 GPU 性能状态通道可取得非零增量，但这不能证明 ANE 通道全零的根因。
- 受控模型包含五个卷积层，`MLComputePlan` 将这些层的首选设备标为 Neural Engine；测试分别运行了约 49,000 次无间隔预测和 332 次限速预测。**首选设备不证明每次实际执行位置**；在一次短时 ANE Instruments 跟踪中未得到推理执行区间，因此仍需能够确认硬件实际执行的对照负载。
- 全部分桶的驻留时间为零时无法计算比例，不能把它解释为 0% 或用电压状态、电源状态替代计算利用率。`powermetrics -s ane_power` 在本机要求超级用户权限；功率也不是利用率。

## 结论与后续验证

目前没有在这台机器上验证出稳定、可持续且语义明确的两项实时占用数据，因此没有把实验计数接入应用，也没有伪造 0%。后续应在兼容的 Xcode / macOS 组合下确认 Metal System Trace 的 Performance Limiters，并用 Instruments 确认实际落在 ANE 的 Core ML 负载，再测试私有通道的更新周期和占用口径。若有可用通道，仍需处理权限、缺失样本、休眠恢复、数据新鲜度和系统版本差异。
