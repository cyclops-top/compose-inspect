# debugImplementation 能力验证结果

日期：2026-11-24。设备：Android 模拟器 sdk_gphone64_arm64（API 36）。工程：AGP 9.2.1、Gradle 9.4.1、Kotlin/Compose compiler 2.4.21。

示例只通过 `debugImplementation` 接入 SDK。分别对齐 Compose 1.10.6 和 1.12.1 后，两个构建均在主页面、Dialog 和 Popup 采到了业务参数及调用位置。记录见 [results.json](results.json)。

- 调用位置已按业务源码校验文件、行号和 UTF-16 offset。普通参数、默认值和对象字段均通过值断言；点击计数器后再次采集，值从 7 变为 8。
- LazyRow 示例有 100 项，采到了当前已组合的 5 项。Lazy 子组合保留为独立表。InlineWrapper 和 NonRestartableCard 的节点可见，示例参数为空。
- 已检查 release 包的 DEX 和 Manifest，未包含 SDK 初始化器、采集器和 tooling-data。
- 本次记录对应两个分别编译的示例，尚未验证同一预编译 AAR 跨 Compose、Kotlin 编译器及不同宿主运行的兼容性。

当前验证步骤见 [SDK 真机验证](../README.md#sdk-真机验证)。

## 桌面组件状态观察 · 2026-11-24

在 API 37 的 arm64 模拟器上，以默认 Compose 1.12.1 构建 debug 示例，使用运行时 SDK 0.1.2、协议 1。桌面采集入口在握手和读取响应时均校验这个版本。选中组件后，右侧「状态」显示 SDK 实际返回的顶层标量参数和交互语义，当时的版本支持跨快照字段关注。当前桌面端仅显示本次采集的字段值。

[六份可回放的 SDK 响应](observation/) 保留了原始字段和值。下表耗时取自每份响应的 Android 主线程 collectMs，各场景单次采样。

| 样本 | 观测结果 | 主线程采集 |
|---|---|---:|
| baseline | ParameterCard.count = 7 | 55.2 ms |
| unchanged | 同一页面再次读取，count = 7 | 20.5 ms |
| incremented | 点击卡片一次，count = 8 | 18.2 ms |
| scrolled | 列表滚动，首个可见索引从 0 变为 6，偏移 −9 px | 18.7 ms |
| dialog | 重启示例进入 Dialog，原进程的观测中断 | 18.1 ms |
| interactions | LazyRow 和网格提供视口、默认 key 不编码；子节点原始三态与父级合并语义分别读取 | 70.4 ms |

运行 `swift test --package-path macOS --filter ComponentStateTests` 可离线验证计数读数、列表复用、进程切换和版本提示。单次点击验证会在点击前复核目标实例。低端物理设备耗时仍待实测。

## 定向研究 · 2026-11-24

在 API 37 arm64 模拟器、独立样例包上分别构建 Compose 1.12.1 与 1.10.6。两次构建均使用 SDK 0.1.2 和协议 1。第二个构建用于实验对照，桌面端的版本校验规则保持精确匹配。性能样例固定显示 24 张卡片，每张有 6 层嵌套。

### 会话开销

每个模式先测 5 次目标进程冷启后的首次采集，再在同一进程测 20 次热采。冷热分别交替模式顺序。冷启行计时从申请转发开始，不包含启动 Activity 的时间。热复用模式只保留已握手的 ADB forward，各次请求仍独立建 socket，逐次核对包、SDK、协议和 PID。计时包含主机接收、解压和 Python JSON 解析，不包含截图或桌面渲染。

| Compose | 冷采单次连接 / 首次建会话，中位 ms | 热采单次连接，中位 / P95 ms | 热采复用，中位 / P95 ms |
|---|---:|---:|---:|
| 1.12.1 | 206.94 / 213.00 | 75.34 / 93.10 | 48.81 / 72.88 |
| 1.10.6 | 206.54 / 203.24 | 71.03 / 86.33 | 44.97 / 83.51 |

100 次请求全部成功。每个版本 40 份热采窗口树的规范化 JSON 哈希一致。主线程 collectMs 的热采中位数分别为 23.10 / 25.77 ms（1.12.1）与 24.39 / 23.72 ms（1.10.6）。本轮继续按需建连：单次点击流程只有两次 SDK 采集，一次复用可节省约 26 ms，UI Automator 等待、截图和主线程遍历仍在。保存连接的收益可在以后需要连续多次读取时重新评估。[会话原型](../tools/benchmark_session.py) · [1.12.1 原始记录](session-1.12.1.json) · [1.10.6 原始记录](session-1.10.6.json)

### 轻量文本读取

同一 instrumentation 进程交替运行完整 SDK 采集与合并语义文本读取，各预热 2 次、实测 20 次。每轮核对 24 个预期卡片标签。计时包含提交到主线程和返回结果；完整模式在计时结束后进行 JSON 编码及内容校验。统计不包含传输、截图、UI Automator 等待和帧耗。

| Compose | 完整读取，中位 / P95 ms | 文本读取，中位 / P95 ms |
|---|---:|---:|
| 1.12.1 | 27.13 / 48.35 | 0.70 / 1.03 |
| 1.10.6 | 27.32 / 39.90 | 0.60 / 0.93 |

该结果支持继续开发 Compose 文本条件的定向读取。原型只在一个 Activity 的 Compose 语义树中验证文本，尚未验证跨窗口遮挡、Android View 和 contentDescription。当前产品仍通过无障碍树确认点击结果，以保留现有条件的语义。[设备端原型](../sample/src/androidTest/java/dev/composeinspect/sample/SemanticsReadBenchmark.kt) · [1.12.1 原始记录](semantics-read-1.12.1.json) · [1.10.6 原始记录](semantics-read-1.10.6.json)

### 内部状态和列表引用

同一调用点生成 A、B 两个实例。每个实例持有局部布尔值，子组件参数和语义均未输出该值。关闭登记时，操作前后的参数名与页面文本相同，两个构建的 SDK 均没有给出具名内部读数。开启登记后，手动采样依次得到 `A=false, B=false`、`A=true, B=false`。移除 A 后仅剩 `B=false`。登记和读取都在 debug 样例中，组件离开组合时释放读取器。它验证的是已知引用按需读取，没有记录两次采样之间的变化。通用面板继续使用已暴露的参数和语义。

同一脚本还核对了两个构建中的 LazyColumn、LazyRow、LazyVerticalGrid：分别有 5、8、6 个视口条目，索引互异。现有基于 state 引用的列表摘要继续交付。[样例](../sample/src/debug/java/dev/composeinspect/sample/InternalStateProbeActivity.kt) · [验证脚本](../tools/validate_state_probe.py) · [1.12.1 结果](state-probe-1.12.1.json) · [1.10.6 结果](state-probe-1.10.6.json)

### 复测

以下命令在 android 目录运行，SERIAL 指向专用测试设备，脚本会重启样例进程。对照版本可用 `-PcomposeVersion=1.10.6` 构建，并同步修改结果标签。

```sh
./gradlew :sample:assembleDebug :sample:assembleDebugAndroidTest -PcomposeVersion=1.12.1
adb -s "$SERIAL" install -r sample/build/outputs/apk/debug/sample-debug.apk
adb -s "$SERIAL" install -r sample/build/outputs/apk/androidTest/debug/sample-debug-androidTest.apk
python3 tools/benchmark_session.py --serial "$SERIAL" --package dev.composeinspect.sample --compose 1.12.1 --output artifacts/session.json
python3 tools/validate_state_probe.py --serial "$SERIAL" --package dev.composeinspect.sample --compose 1.12.1 --output artifacts/state.json
adb -s "$SERIAL" shell am instrument -w dev.composeinspect.sample.test/dev.composeinspect.sample.SemanticsReadBenchmark
```

### 整体验收回归

2026-11-24 按 API 37 模拟器验收通过。低端真机上的采集耗时、掉帧和单次点击表现单列为后续实测项。

macOS 完整回归共 169 项，164 项通过、5 项因未启用对应的可选测试环境而跳过，零失败。另在模拟器上对无障碍树、输入窗口和截图命令各额外延迟 1 秒，复跑单次点击端到端测试：预期已存在时未执行点击，成功和超时两次各只增加一个计数，超时保留了结果快照。这项验证覆盖慢命令路径，目标低端物理设备的 UI 帧耗与采集预算仍待实测。

Android collector 与 protocol 共 24 项单测通过。debug、release 及 instrumentation APK 均构建成功，已核对 release APK 的 DEX 与 Manifest：发布样例不含采集 SDK 或内部状态原型，语义计时器只在测试 APK 中。重新构建的 macOS Release 可执行文件与 /Applications/CompScope.app 中运行的文件一致，应用签名通过严格验证。

## 低性能真机的快速采集

2026-11-25，GXS‑V1（API 34），Compose 1.12.1。固定样例页面有 24 张卡片，遍历 2,949 个 group。两种模式都开启窗口截图，每种先预热 2 次，再轮换顺序各采集 20 次。

| 模式 | 主线程中位数 | 主线程 P95 | 请求响应中位数 |
|---|---:|---:|---:|
| 完整采集 | 698 ms | 898 ms | 992 ms |
| 快速采集 | 163 ms | 242 ms | 490 ms |

两种模式均输出 2,450 个节点，名称、层级顺序和边界的哈希一致。完整模式读取了 829 个参数。请求响应耗时从复用的 ADB 转发端口发起请求开始，包含接收窗口 PNG、解压和解析 SDK JSON，到桌面导入与绘制之前结束。桌面端真机测试另行验证了完整、快速、恢复完整及快速结合工程源码筛选四次抓取。

## 首次绘制后预热 Compose 签名索引

2026-11-25，GXS‑V1（API 34），Compose 1.12.1，正常 debug SDK。每次验证均重新启动样例进程。下表为每组 3 次的中位数。请求读取 2,949 个 group，包含首次编码与 ADB 传输，未请求截图。

| 首次抓取条件 | 请求等待签名索引 | 请求响应 |
|---|---:|---:|
| 旧 SDK，启动后 6 秒抓取 | 旧 SDK 未单独计时 | 5,226 ms |
| 新 SDK，清除索引并立即抓取 | 3,092 ms | 5,172 ms |
| 新 SDK，清除索引并在启动后 6 秒抓取 | 1.9 ms | 2,123 ms |
| 新 SDK，保留索引并立即抓取 | 2.0 ms | 2,247 ms |

6 秒是测试等待时间，SDK 由首次绘制触发。预热组在首个 SDK 请求之前已检查到索引文件。另将索引截断后启动，验证了自动重建。所有快照的树哈希与过滤计数相同。ADB 启动耗时的各组中位数介于 2.42–2.52 秒；样本量不足以推断启动帧率。[逐次记录](../research/native-encoding/pipeline/results/startup.json)

## Gradle 构建期 Compose 签名索引

2026-11-25，GXS‑V1（API 34），Compose 1.12.1。对同一 sample 分别启用和关闭插件，各测 3 次。每次清除设备端签名缓存，重启后立即请求节点树，不请求截图。六次请求的窗口节点树哈希一致，均触发返回值调用过滤。

| 中位数 | 设备扫描 DEX | APK 内置索引 |
|---|---:|---:|
| 首次请求等待索引 | 3,158 ms | 60 ms |
| 首次节点树响应（含 ADB 传输） | 5.28 s | 2.40 s |

逐项核对最终 debug APK 的 DEX 扫描结果与打包索引，Compose 1.10.6 的 231 条声明和 1.12.1 的 239 条声明均完全一致。1.12.1 样例索引未压缩大小为 12,577 字节。release APK 未包含索引。

在独立 sample 工程中从本地 Maven 接入插件，预热 Gradle daemon，关闭构建缓存，离线交替比较开关插件。启用插件的 4 轮中，索引任务在 clean 后分别用时 349、309、587、251 ms，中位数 329 ms。单文件新增一个有返回值的 Composable 后分别用时 41、41、47、39 ms，中位数 41 ms，声明数从 239 增至 240。以上为 sample 工程的任务耗时，整次构建耗时有波动。
