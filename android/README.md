# ComposeInspect Android SDK 验证工程

验证业务应用**只增加 `debugImplementation`**、不修改 Kotlin/Java/业务 Manifest 时，能否采集 Compose 调用树、参数和源码位置。本工程已接入 macOS 自动抓取，SDK 通过 Maven Central 分发。

## 模块

| 模块 | 职责 |
| --- | --- |
| `protocol` | 协议版本、JSON 辅助函数和 socket 命名，不依赖 Compose |
| `compose-collector` | 启用 tooling 数据、遍历各窗口的 Composition 表、读取参数与调用位置、有限深度的值编码 |
| `inspector-sdk` | Manifest 自动初始化、Activity 生命周期、ADB LocalSocket 通信与调试包检查 |
| `sample` | 普通业务 Compose 示例；唯一 SDK 接入点在 Gradle `debugImplementation` |
| `tools` | SDK 采集、参数与源码位置断言、debug/release 包检查 |

依赖方向：`sample (debug) → inspector-sdk → compose-collector → protocol`。`inspector-sdk` 也直接使用 `protocol`。release 不依赖 SDK。

## 原理与边界

SDK 的非导出 ContentProvider 随 AAR Manifest 合并，在 Activity 首次组合前启用 `isDebugInspectorInfoEnabled`。Compose 自身记录 `inspection_slot_table_set` 并调用参数信息收集逻辑。SDK 读取 `CompositionData.mapTree`，不替换 `setContent`，不设置预览模式，不要求业务包装 Composable。

- Android 29+ 使用 `WindowInspector.getGlobalWindowViews()` 包含 Dialog/Popup；26–28 回退到 Activity decor，并明确返回窗口覆盖限制。
- Android 14+ 的新版 SDK 支持按窗口配对截图。Mac 端选择窗口时会切换到对应的 PixelCopy 图像，并按窗口屏幕偏移显示。低版本系统或旧版 SDK 使用 ADB 整屏截图，与组件树并行获取。窗口像素复制和树遍历之间可能跨帧。
- 在主线程读取 Composition 表；socket 工作在后台线程，单次请求有超时。源码位置是**调用点**，不是函数定义；只包含文件名、行号、UTF-16 offset/length 和包 hash，不含完整源文件路径。
- `source.line` 保留 tooling 原始值。在已测两个版本中它是 1 起算，已用业务源码行和 offset 验证；不能仅根据 tooling 的旧注释再加 1。
- 声明 `source-only-v1` 的 SDK 支持每次抓取传入 `onlySourceNodes`，在读取参数之前跳过无源码文件名的节点。可选的 `sourceKeys` 限定工程中唯一的文件名与包哈希组合。保留子组件顺序，只为可关联到保留组件的布局读取语义与样式。
- 采集时直接提升纯内容包装的子节点，保留顺序。SDK 检查单个 Composable 内容槽、同尺寸子分支和独立布局边界；文本、交互参数或额外可见分支会阻止这项通用折叠。外观层为空本身不会触发过滤。
- SDK 在首次采集时从当前 APK 和 split APK 读取 Compose 方法签名，并在进程内复用。能确认返回非 Unit 的调用会在编码前提升其子节点，计数见 `stats.filteredValueCalls`。声明信息缺失或同文件同名重载的返回类别冲突时，返回类型规则保留节点。
- 原始 Composition 表分别输出，**尚未跨表拼接 Lazy 子组合，也未与 Android View 树合并**。
- 参数编码最多 3 层、20 个元素、2048 字符；截断或不支持的类型会显式标记。标准 Shape、盒装 Color/Dp 已有专用编码；其他未支持的 Android/AndroidX 对象和回调保留类型，尚不支持参数续读。
- `complete` 只表示这次发现的表没有读取错误，不表示任意应用的所有窗口、所有参数和所有代码路径都完整。
- 只处理默认进程。SDK 仅在 debuggable 应用初始化；socket 校验 shell/root/同 UID 的 peer credentials，不开放 TCP 监听、不声明 INTERNET 权限。
- 初始化会启用 Compose 的额外参数记录，存在调试内存与 CPU 开销。本轮没有完成性能基准。

## 构建和接入

需要 JDK 21、Android SDK Platform 37；Gradle Wrapper 固定 9.4.1，AGP 9.2.1，Kotlin/Compose compiler 2.4.21。SDK 路径通过 `ANDROID_HOME` 或未纳入版本控制的 `local.properties` 提供。

在 `android/` 目录执行：

```sh
./gradlew :sample:assembleDebug
```

示例的唯一接入：

```kotlin
debugImplementation(project(":inspector-sdk"))
```

`sample/src/main/` 不含 SDK import、初始化代码、SDK 专用 Manifest 或检查用 Composable 包装。

## Compose 版本

当前默认验证 1.12.1，可切换到 1.10.6：

```sh
./gradlew :sample:assembleDebug -PcomposeVersion=1.10.6
```

这个属性同时选择示例与采集模块的 Compose/tooling 依赖。已测矩阵见 [验证结果](validation/RESULTS.md)。**不代表已经验证一个预编译 SDK 可以兼容所有 Compose 版本**，也不是强制业务升级到 1.12.1。

当前 project 依赖的默认值仍是 1.12.1，直接接入较旧业务项目而不对齐版本可能被 Gradle 升级。发布前应确定支持范围和依赖策略：最低支持版本编译、同版本 tooling 对齐，并验证同一 SDK 二进制在各宿主版本运行。不能简单用 `compileOnly` 删除 tooling 依赖，运行时仍需要它。

## 通过 ADB 采集

先安装 SDK debug APK、打开示例应用，再从 `android/` 执行：

```sh
python3 tools/capture.py --serial DEVICE_SERIAL --command hello --output artifacts/hello.json
python3 tools/capture.py --serial DEVICE_SERIAL --output artifacts/capture.json
```

支持 `--adb /path/to/adb` 和 `--package your.application.id`。工具建立随机端口的 ADB forward，结束时只清理自己的 forward。此脚本使用单行 JSON 请求和响应，支持的命令为 `hello` 与 `capture`。

## SDK 真机验证

连接已授权设备后，在 `android/` 中运行：

```sh
python3 tools/validate.py --serial DEVICE_SERIAL
# 验证单一 Compose 版本
python3 tools/validate.py --serial DEVICE_SERIAL --versions 1.12.1
```

脚本构建 debug 和 release 包并检查 SDK 的 DEX 与 Manifest；仅安装、重启示例调试包。它在主页面、Dialog 和 Popup 检查参数值、默认值、源码行与 offset，并点击计数器验证重组后的值。每个版本的 APK、原始 SDK JSON、构建日志和 `validation.json` 写入 `artifacts/<版本>/`。

## Maven 发布

与 spear 使用相同的 `com.vanniktech.maven.publish:0.37.0` 插件，签名后发布到 Maven Central。
版本由 `gradle.properties` 的 `sdkVersion` 统一控制，当前版本为 `0.1.4-SNAPSHOT`。

在业务应用的调试依赖中添加：

```kotlin
debugImplementation("top.cyclops:compose-inspector:0.1.4-SNAPSHOT")
```

同时发布 `compose-inspector-collector` 和 `compose-inspector-protocol`，均属于 `top.cyclops`；主制品会传递依赖它们。发布的是库的 release 变体，使用方仍须使用 `debugImplementation`，不要加入生产包。

本地构建、签名与发布验证：

```sh
./gradlew publishToMavenLocal
```

凭据和签名信息沿用用户级 `~/.gradle/gradle.properties` 或环境变量配置，不要提交到仓库：
`mavenCentralUsername`、`mavenCentralPassword`、`signingInMemoryKey`、`signingInMemoryKeyPassword`（需要时加 `signingInMemoryKeyId`）。

正式上传前，在用户级 Gradle 属性中设置 `sdkScmUrl` 为实际仓库 HTTPS URL（不带 `.git`）。仓库可以私有；当前按用户要求与 spear 共用 `https://github.com/cyclops-top/hilt-plus`，已在项目属性中设置。缺少该属性会阻止远端发布。

```sh
./gradlew publishToMavenCentral
```

上传后在 Central Portal 检查并发布；如需同时自动发布，运行 `./gradlew publishAndReleaseToMavenCentral`。Maven Central 制品及 sources JAR 将公开，GitHub 仓库可以继续私有。Android SDK 源码采用本目录 `LICENSE` 中的 Apache-2.0。


## 性能与压缩协议（0.1.2）

升级采集 SDK 后，重新构建并安装业务应用的调试包。

- `hello` 声明 `gzip-json-v1` 时，新 macOS 客户端发送 `capture-gzip`。响应为 4 字节大端压缩长度 + 单个 gzip member，解压后仍为完整、以换行结尾的原始 JSON。桌面端支持运行时 SDK 0.1.3 和 0.1.4-SNAPSHOT、协议 1 和压缩采集能力。
- Compose/View 状态只在主线程读取；对象字段元数据仅在单次采集中缓存，实际值始终重新读取。编码、快速压缩和 socket 写入在 SDK 工作线程执行。
- macOS 复用已解析文档，避免规范化数据再次解析；截图 I/O 与原始 JSON 解析并行。压缩输入与解压输出均有大小限制，CRC、截断、额外数据会报错。
- `tools/capture.py` 默认写紧凑 JSON，`--pretty` 才生成缩进输出。深层树的缩进文件可能远大于实际传输数据，不应用作传输性能基线。

真机编码基准（fixture 只进入测试 APK，不进入发布制品）：

```sh
./gradlew :protocol:assembleDebugAndroidTest -PbenchmarkJson=/absolute/path/capture.json
adb install -r protocol/build/outputs/apk/androidTest/debug/protocol-debug-androidTest.apk
adb shell am instrument -w dev.composeinspect.protocol.test/dev.composeinspect.protocol.EncodingBenchmark
```

2026-11-02，设备 GX202606000036WL，cn.bs 同一份 4,220,492 字节数据（8,365 个导入节点）：
Android 编码基准第 4 轮约 4.00s → 2.31s；快速 gzip 约 33ms，含头帧 425,857 字节。
macOS Debug 紧凑数据导入约 4.14s → 1.07s；Release 解压 + 导入约 0.25s。
这些是分阶段基准，不包含完整端到端抓取与界面渲染；之前 129s 测试含 106MB 美化 JSON 的重复解析，不能与正常传输直接比较。

更新 cn.bs 后，真实 gzip 通道完整集成测试通过：当前 2,200 节点页面，首次 6.66s，预热后 3.96s（包含设备识别及后续交互）。预热轮读取 2.00s、截图/解析 0.78s、建树 0.07s，Android 主线程采集 1,143ms。


## SDK 样式：shape、padding、背景色

SDK 从每个 AndroidComposeView 的 LayoutNode/ModifierInfo 读取实测样式层，按从外到内的顺序保存；不根据父子节点的尺寸差推测 padding。每个窗口的 `styleCatalogs` 每个 host 只存一份，Composition 表用 `styleCatalogIndex` 引用；macOS 在对应 host 范围内关联并展示样式，边界相同而无法消歧时不猜测归属。

- shape：矩形、圆形/胶囊、RoundedCornerShape、CutCornerShape 及 Absolute 变体；保留 dp/px/% 配置及归一化后的实际像素角尺寸，支持 RTL。
- padding：普通/absolute padding 和 PaddingValues；显示物理左右上下 dp 值，保留每层真实边界。
- 背景色：纯色转换到 ARGB，包含透明度，保留多层背景及其各自 shape。
- 样式边界已是屏幕坐标；tooling 调用树边界仍按窗口偏移换算，避免重复偏移。记录可携带局部 density。
- 自定义 Shape/Brush、drawBehind 和动态 graphicsLayer block 尚不还原，明确保留未知/未支持信息。反射适配失败保留诊断，不伪造样式，也不影响调用树采集。

验证入口（业务示例不含 SDK 专用 API）：

```sh
./gradlew :compose-collector:testDebugUnitTest :sample:assembleDebug
adb install -r sample/build/outputs/apk/debug/sample-debug.apk
adb shell am force-stop dev.composeinspect.sample
adb shell am start -W -n dev.composeinspect.sample/.MainActivity --es scenario styles
python3 tools/capture.py --serial DEVICE_SERIAL --output artifacts/styles-1.12.1.json
cd ../macOS
SDK_STYLE_CAPTURE="$PWD/../android/artifacts/styles-1.12.1.json" swift test --filter SDKStyleTests
```

可加 `-PcomposeVersion=1.10.6` 切换版本验证。SDK 及 macOS 均需更新；业务 debug APK 重新构建安装后才包含新的采集逻辑。

2026-11-02：Compose 1.10.6 / 1.12.1 的采集模块单元测试、示例构建和设备样式采集均通过，样式目录无采集错误；两份真机数据均通过 macOS SDKStyleTests，相关 SDK/样式/绘制回归共 19 项通过。任意版本兼容性仍需分别验证。


## SDK 点击语义

SDK 在主线程读取 LayoutNode 自身的 SemanticsConfiguration，输出 `interaction.hasClickAction / hasLongClickAction / disabled`；仅检查动作是否存在，不执行回调，也不合并后代动作。`hello` 声明 `layout-interactions-v1`（及 `style-layers-v1`）。

macOS SDK 适配器沿 Composition 的实际布局归属映射到公共 `unmergedSemantics`。匿名 layout 向拥有它的调用节点提供语义，遇到下一层 layout 就停止；多个根布局或不同边界的包装节点不推断为可点击。仅可点击筛选忽略普通 onClick 参数、仅长按动作和禁用控件。自定义 pointerInput 手势如果未声明 OnClick 语义，仍无法据此判定为点击。

验证示例使用 `--es scenario interactions`，包含启用点击、禁用点击、普通文本、仅长按、自定义 OnClick 语义和 CompositionLocalProvider 包装。采集后设置 `SDK_INTERACTION_CAPTURE=/absolute/path/capture.json` 执行 macOS 的 `SDKInteractionTests`。2026-11-02，Compose 1.10.6 / 1.12.1 的交互编码单元测试通过；1.12.1 示例已在设备采集验证，各布局均有交互字段且无采集错误。

### 悬浮窗选择

采集包含目标进程内可见的悬浮窗。窗口菜单从底层开始编号，最底层为窗口 1；默认预览前台窗口。其他进程的悬浮窗需要选择对应采集目标。


## 列表视口与交互状态

桌面端的「状态」页显示 LazyColumn、LazyRow、LazyVerticalGrid 和 LazyHorizontalGrid 的视口摘要。SDK 在对应调用的 state 参数上读取 layoutInfo，返回主轴视口起止、可见条目数、每项实际索引、偏移和长度。网格还返回列表局部二维位置与尺寸。单位均为 px，单次最多传回前 100 条。key 仅展示可安全编码的标量，无法据此确认它是否是持久业务标识。

原始和合并语义分别标记来源。合并树通过同一宿主的语义节点 ID 关联，已合并进父级的子节点可能没有独立读数。Selected、Focused 和 ToggleableState 仅在 Compose 提供相应字段时出现。
