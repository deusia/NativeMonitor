# 神经加速器实时占用调研

2026-11-13，在 Apple M5 Max、macOS 27.3 和 Xcode / Instruments 27.2 上验证。以下结果仅适用于这台机器及本次测试，不代表其他版本的系统行为。

## GPU Neural Accelerator

- Apple 的 [Metal System Trace 演示](https://developer.apple.com/videos/play/tech-talks/111432/)使用 `Performance Limiters` 计数器组展示 Neural Accelerator 利用率；该硬件位于 GPU 核心中，与独立的 Apple Neural Engine 不同。
- 本机 Metal `MTLDevice.counterSets` 仅列出 `timestamp`，不能据此获取神经加速器占用。
- `xctrace record --template 'Metal System Trace' --all-processes --time-limit 5s --no-prompt` 可以完成录制。默认计数器组为 `None`，导出的计数器信息只有 `RT Unit Active`，没有目标指标。
- 在 Instruments 图形界面选择 `Performance Limiters` 和即时处理后，GPU Counters 轨道没有结果；跟踪报告多条 `Cannot find GPU device for counter values` 和 `Cannot find GPU device for shader profiler values`。目前未确定具体原因。
- 本机 Instruments 的 `GPUCounterGraph.plist` 定义了 `MXU Utilization`，显示名称为 `Neural Accelerator Utilization`，单位为峰值 Neural Accelerator 性能的百分比；定义存在不代表本机已成功采集。`xctrace` 的 `--show-recording-options` 未列出 Metal GPU Counters 的计数器组选项。
- macOS 的 `metalperftrace listen --json` 可提供实时 Metal 性能信息；在本机监听 5 秒没有输出，尚不能确认能否提供该计数器或用于全系统监控。
- 使用 Metal TensorOps 矩阵乘法测试负载重新录制，测试程序成功返回，Instruments 的 Metal Encoder Hierarchy 中也出现该进程；选择 `Performance Limiters` 后仍报告 `Cannot find GPU device for counter values`，未获得目标计数器。无法确定失败是否与权限、驱动或工具版本有关。
- 后续用 Instruments 保存启用 `Performance Limiters` 的自定义模板，再以 `xctrace --launch` 单独启动 TensorOps 矩阵测试。导出的 `gpu-counter-info` 包含 88 项，其中 `Neural Accelerator Utilization` 的编号为 49；`gpu-counter-value` 的前 100 万行中该指标先为零，随后出现约 6.25% 的非零样本。编号来自本次录制的元数据，不应假定其他机器或录制相同。该结果证明这次单进程跟踪能够取得数值，不证明已找到全系统持续采集接口。
- 该次单进程录制持续约 4.3 秒，生成约 1.4 GB 跟踪文件；导出计数器时观察到 `xctrace` 的常驻内存约 4.2 GiB。为控制开销，在读取前 100 万行后中止导出；此前录制进行中直接导出也失败。因此不能将这种录制和导出方案直接用于常驻实时监控。
- 2026-11-14 新建仅包含 Metal Application 且启用 `Performance Limiters` 的精简模板，限制短时滚动窗口：一次 4 秒单进程跟踪生成约 116 MB，导出前 100 万行用时约 25 秒，并读到约 6.52% 的非零 Neural Accelerator 样本；录制中导出仍报 `Document Missing Template Error`。另一次 3 秒限时录制及处理历时约 16 秒，`xctrace` 峰值约 807% CPU、7.3 GiB 常驻内存，生成约 134 MB 文件。这些是本机单次观察，不能作为其他设备的资源消耗保证。
- 同一精简模板以全进程模式采集并运行 TensorOps 测试，跟踪文件约 121 MB；从已完成的跟踪导出约 126 万行后找到非零目标样本，最大约 6.32%。因此本机的全进程录制也能提供目标计数器，但仍没有验证低开销或录制中读取方式。
- 以普通用户直接探测 Xcode 私有的 `DTGPUDataSource`，可发现 13 和 14 号计数器组，但报告 `Fail to instantiate AGXGPURawCounterSourceGroup`；尝试配置 13 号组并启动采集时返回失败，未收到回调。具体原因尚未确定，不能据此断言只是权限问题；该私有接口还依赖 Xcode，不能直接作为应用的稳定依赖。
- 用户以管理员权限运行相同的直接服务探针，仍报告 `Fail to instantiate AGXGPURawCounterSourceGroup`，启动采集返回失败、没有回调。单纯使用 sudo 未解决初始化问题；本次未进一步改变系统安全配置。
- 枚举本机 IOReport 可见的通道名称，未发现名称包含 `Neural`、`MXU`、`tensor` 或 `matrix` 的通道；名称枚举不能排除隐藏通道，也不代表系统不存在其他数据源。
- 系统信息可识别 32 核 M5 Max GPU，驱动为 `com.apple.AGXG17X`。本机 `DevToolsSecurity -status` 显示关闭；该设置涉及 Apple 签名调试与性能分析工具的额外密码提示，不能据此认定采集失败是权限问题。Apple 的 [Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)显示 Xcode 27.2 支持在 macOS 26.6 或更新版本运行，但不代表已验证当前系统构建的每项性能计数器。
- 录制进行时尝试 `xctrace export --toc` 返回 `Document Missing Template Error`。短时全系统跟踪会产生较大的临时文件和处理开销，因此本次没有找到可直接用作菜单栏秒级数据源的可靠路径。不能由这一实验断言其他版本的 Instruments 无法实时显示计数器。

## 独立 Apple Neural Engine

- 2026-11-14 在 M5 Max / macOS 27.3 上以普通用户每 0.25 秒采集 `Energy Model / ANE0`，连续 120 次采样中观察到 15 次发布，间隔约 2.04–2.10 秒；累计能量变动时，`RawElements` 中的驱动发布时间也随之变化。驱动时间戳及布局属于私有实现，可能随系统更新改变。
- 受控 ANE 卷积负载期间，`ANE0` 在稳定区间每次发布约增加 1.5–1.7 J；按约 2.06 秒发布间隔换算约 0.73–0.81 W。相同时间采集的另一条私有 CLPC ANE 能量通道约为 0.70–0.76 W。两者来自同一系统，属于交叉对照而非独立功率仪的物理校准；单次采样可能受发布时序影响。
- 另一次稳定负载对照的 10.09 秒窗口内，按累计能量计算，能量模型平均约 0.761 W，CLPC 平均约 0.734 W，前者高约 3.7%；窗口起止与驱动发布时刻不完全对齐。
- 对照中，直接按一秒轮询间隔计算 `ANE0` 出现 0 W 与约 1.5 W 交替，因此不能把零增量当作实时零功率；应以有效的驱动发布时刻作为间隔，并在时间戳停更或格式变化时显示不可用。
- 接入后的实机界面测试中，空闲时显示约 0 W，受控负载期间显示约 0.68 W，结束后回落。该读数为最近一次已发布区间的平均功耗，不是 ANE 利用率；未用外部功率仪独立校准。
- [aneperf](https://github.com/tmc/aneperf) 描述了通过私有 `libIOReport` 的 `Fast-Die CE` 百分比分桶计算估算值的方案；它不是 Apple 公布的稳定监控契约。
- 本机可在 `PMP0 / Fast-Die CE / ANE0` 发现 21 个 0%–100% 分桶。对该组进行连续两秒差分采样时，所有桶均为零；并行执行受控 Core ML 测试时也没有获得有效增量。相同采样机制读取 GPU 性能状态通道可取得非零增量，但这不能证明 ANE 通道全零的根因。
- 受控模型包含五个卷积层，`MLComputePlan` 将这些层的首选设备标为 Neural Engine；测试分别运行了约 49,000 次无间隔预测和 332 次限速预测。**首选设备不证明每次实际执行位置**；在一次短时 ANE Instruments 跟踪中未得到推理执行区间，因此仍需能够确认硬件实际执行的对照负载。
- 使用第三方 `aneperf/testworkload` 通过私有 ANE 接口执行身份模型，输出与输入一致；随后卷积测试成功执行约 44,000 次，但采样期间 `ANE0` 等分桶仍无增量。一次 Instruments 跟踪只看到模型编译与加载区间，没有捕获推理执行区间，不能据此确认该分桶的计算口径或运行位置。
- 用户在终端执行 `sudo powermetrics -n 3 -i 1000 -s gpu_power,ane_power` 的三次采样中均有 GPU 结果，没有 ANE 数据；缺少 ANE 输出不能解释为零功耗。
- 进一步在持续 ANE 卷积测试期间单独运行 `sudo powermetrics -n 3 -i 1000 -s ane_power`，三个采样均未输出 ANE 数值。该测试进程于 23:45:00 启动，采样时间为 23:45:26–23:45:28，测试最终报告约 189,000 次调用成功。
- 在另一轮持续 ANE 卷积测试中，普通用户与管理员分别运行同一个 `IOReport` 分桶探针，各采集六次；两者的 `ANE0` 各分桶均无增量。管理员探针与测试进程运行时间重叠，这表明单纯使用 sudo 没有解决本机该通道的读取问题；测试仍未独立证实每次推理的硬件执行位置。
- 全部分桶的驻留时间为零时无法计算比例，不能把它解释为 0% 或用电压状态、电源状态替代计算利用率。`powermetrics -s ane_power` 在本机要求超级用户权限；功率也不是利用率。

## 结论与后续验证

已在单进程 TensorOps 跟踪中读到 Neural Accelerator 的非零样本，但尚未验证低开销、全系统、持续读取方式；ANE 也尚无有效占用样本。因此没有把实验计数接入应用，也没有伪造 0%。后续需要验证可持续读取的 GPU 数据源，并用 Instruments 确认实际落在 ANE 的负载，再测试私有通道的更新周期和占用口径。若有可用通道，仍需处理权限、缺失样本、休眠恢复、数据新鲜度和系统版本差异。
