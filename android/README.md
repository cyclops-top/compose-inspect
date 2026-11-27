# ComposeInspect Android SDK 验证工程

验证业务应用**只应用 CompScope 插件**、不修改 Kotlin/Java/业务 Manifest 时，能否采集 Compose 调用树、边界和源码位置。本工程已接入 macOS 自动抓取，SDK 通过自建 Reposilite 分发。

## 模块

| 模块 | 职责 |
| --- | --- |
| `protocol` | 协议版本、JSON 辅助函数和 socket 命名，不依赖 Compose |
| `compose-collector` | 启用 tooling 数据、遍历各窗口的 Composition 表、读取边界与源码位置 |
| `inspector-sdk` | Manifest 自动初始化、Activity 生命周期、ADB LocalSocket 通信与调试包检查 |
| `sample` | 普通业务 Compose 示例；由插件接入调试 SDK 并生成签名索引 |
| `tools` | SDK 采集、边界与源码位置断言、debug/release 包检查 |

依赖方向：`sample (debug) → inspector-sdk → protocol`。采集器和 tooling-data 随桌面应用分发。release 不依赖 SDK。

## 原理与边界

SDK 通过 AndroidX Startup 初始化，在 Activity 首次组合前启用 `isDebugInspectorInfoEnabled`。Compose 自身记录 `inspection_slot_table_set` 并调用参数信息收集逻辑。SDK 读取 `CompositionData.mapTree`，不替换 `setContent`，不设置预览模式，不要求业务包装 Composable。

- Android 29+ 使用 `WindowInspector.getGlobalWindowViews()` 包含 Dialog/Popup；26–28 回退到 Activity decor，并明确返回窗口覆盖限制。
- Android 14+ 的新版 SDK 支持按窗口配对截图。Mac 端选择窗口时会切换到对应的 PixelCopy 图像，并按窗口屏幕偏移显示。低版本系统或旧版 SDK 使用 ADB 整屏截图，与组件树并行获取。窗口像素复制和树遍历之间可能跨帧。
- 在主线程读取 Composition 表；socket 工作在后台线程，单次请求有超时。源码位置是**调用点**，不是函数定义；只包含文件名、行号、UTF-16 offset/length 和包 hash，不含完整源文件路径。
- `source.line` 保留 tooling 原始值。在已测两个版本中它是 1 起算，已用业务源码行和 offset 验证；不能仅根据 tooling 的旧注释再加 1。
- SDK 默认使用快速采集，并声明 `geometry-only-v1`。支持 `component-details-v1` 时，客户端可通过 `geometryOnly: false` 请求详情，额外读取组件专属参数、布局样式、交互语义和 Lazy 列表视口。快速采集保留树结构、调用位置和工具链测得的边界，跳过参数、交互语义和样式读取。依赖参数判定的内容包装节点可能保留。可与源码过滤及窗口截图组合使用。
- 声明 `source-only-v1` 的 SDK 支持每次抓取传入 `onlySourceNodes`，在读取参数之前跳过无源码文件名的节点。可选的 `sourceKeys` 限定工程中唯一的文件名与包哈希组合。保留子组件顺序。
- 采集器检查已安装 APK 的 Compose 方法。无布局调用若仅执行状态读取、缓存并直接调用或逐层传递同一个无参内容插槽，会提升其子节点。所有分支都参与判定；含自有 UI、插槽来源不明确或同名声明有歧义时保留该层。
- Startup 在首帧前开启 Compose 检查并跟踪 Activity。后台 LocalSocket 等待桌面连接。首次抓取按需初始化签名索引，同一进程复用。
- 签名索引用于提升返回非 Unit 的调用，计数见 `stats.filteredValueCalls`。响应的 `timings.returnIndexWaitMs` 是本次请求等待索引的时间，不计入 UI 线程采集耗时。
- 原始 Composition 表分别输出，**尚未跨表拼接 Lazy 子组合，也未与 Android View 树合并**。
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
plugins { id("top.cyclops.compose-inspector") }
```

`sample/src/main/` 不含 SDK import、初始化代码、SDK 专用 Manifest 或检查用 Composable 包装。

## 2.0 桌面采集器

首次抓取通过已认证的 LocalSocket 完成 hello → prepare → install（缺包时）→ capture-gzip。桌面按发布清单发送采集器版本与摘要。启动器在私有 code cache 校验 SHA-256、ECDSA 发布签名和 JAR 清单的 Implementation-Version，原子替换只读 DEX JAR。相同进程复用已加载实例；新进程重新验证磁盘缓存。已加载其他版本时，重启业务进程后即可切换。抓取诊断记录采集器版本、PID、缓存来源和传包字节数。早期 2.0 启动器由桌面通过发布清单和已确认的 JAR 摘要识别版本。

桌面工程包含已签名的采集器。修改采集实现后，使用 JDK 21 运行 `android/tools/package-collector.sh`，同时提交更新的 JAR 和签名。签名私钥由 `COMPSCOPE_COLLECTOR_KEY` 指定，默认位置为 `~/.config/compscope/collector-v2.pem`。启动器内的公钥必须匹配。

## 编译期签名索引插件

在应用模块应用插件，CompScope 会从这个 debug 变体的项目字节码和依赖 JAR 中提取 Compose 返回值声明，将结果打入 APK 的 `assets/composeinspect/return-index-v1`。首次抓取时，采集器在 socket 工作线程优先读取这个索引。插件与 SDK 可从 Maven 仓库接入：

```kotlin
// 应用模块 build.gradle.kts
plugins {
    id("com.android.application")
    id("top.cyclops.compose-inspector") version "2.0.0-SNAPSHOT"
}
```

开发版插件按 build type 自动添加同版本 SDK。默认开启 `debug`，关闭 `release` 和其他自定义类型。已发布的 `0.1.4` 插件仍需显式添加下文所列 SDK 依赖。

在业务工程的 `settings.gradle.kts` 中，将 `maven("https://repo.tick-tick.cn/releases")` 加入 `pluginManagement.repositories` 和 `dependencyResolutionManagement.repositories`，保留原有 Google 和 Maven Central 仓库。本地联调时，在这两处使用 `mavenLocal()`，并在本仓库的 `android/` 执行 `./gradlew :signature-plugin:publishToMavenLocal publishToMavenLocal` 发布本地插件标记、插件实现及 SDK。仓库内的 sample 通过 included build 直接应用插件。

需要覆盖默认值时，在应用模块的 `build.gradle.kts` 导入扩展属性：

```kotlin
import dev.composeinspect.gradle.composeInspect

android {
    buildTypes {
        debug { composeInspect = false }
    }
}
```

开关作用于该 build type 的所有产品风味，同时控制插件添加的 SDK 依赖和签名索引任务。显式开启的构建类型只有在未混淆且应用无动态特性模块时生成索引。SDK 仅在可调试 APK 中启动采集。插件在 AGP 9.2.1 上验证。安装了多个 APK 的应用保守地使用设备端现有路径，缺少或损坏的随包索引也会回退。Gradle 按输入复用任务结果；任务重跑时按 JAR 内容哈希复用签名分析，并重新合并全局的同名冲突。

验证同一 APK 的 DEX 与随包索引时，先生成 APK，再运行比对：

```sh
./gradlew :sample:assembleDebug
COMPOSEINSPECT_INDEX_APK="$PWD/sample/build/outputs/apk/debug/sample-debug.apk" ./gradlew :compose-collector:testDebugUnitTest --tests '*PackagedIndexTest'
```

## Compose 版本

当前默认验证 1.12.1，可切换到 1.10.6：

```sh
./gradlew :sample:assembleDebug -PcomposeVersion=1.10.6
```

这个属性同时选择示例与采集模块的 Compose/tooling 依赖。已测矩阵见 [验证结果](validation/RESULTS.md)。**不代表已经验证一个预编译 SDK 可以兼容所有 Compose 版本**，也不是强制业务升级到 1.12.1。

业务 App 提供 Compose UI 与 runtime。桌面采集器单独打包 tooling-data 和签名索引读取依赖。切换 Compose 编译基线后，需要用同一份签名 JAR 在各目标宿主版本上验证。

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

脚本构建 debug 和 release 包并检查 SDK 的 DEX 与 Manifest；仅安装、重启示例调试包。它在主页面、Dialog 和 Popup 检查组件树、边界、源码行与 offset，并验证缺省请求也只返回快速采集字段。每个版本的 APK、原始 SDK JSON、构建日志和 `validation.json` 写入 `artifacts/<版本>/`。

## Maven 发布

SDK 和 Gradle 插件的发布目标为 `https://repo.tick-tick.cn`。正式版发布到 `releases`。日常 SNAPSHOT 联调使用上文的 `publishToMavenLocal` 命令。
版本由 `gradle.properties` 的 `sdkVersion` 统一控制，本地版本为 `2.0.0-SNAPSHOT`。

使用已发布的 0.1.4 时，在业务应用的调试依赖中添加：

```kotlin
debugImplementation("top.cyclops:compose-inspector:0.1.4")
```

同时发布 `compose-inspector-collector` 和 `compose-inspector-protocol`，均属于 `top.cyclops`；2.0 启动器只依赖协议制品和 AndroidX Startup。发布的是库的 release 变体，使用方仍须使用 `debugImplementation`，不要加入生产包。

在本机的 `~/.gradle/gradle.properties` 填写 Reposilite 令牌凭据：

```properties
reposiliteUsername=你的令牌名称
reposilitePassword=你的令牌密钥
```

从 `android/` 发布 SDK、插件实现及插件标记：

```sh
./gradlew :signature-plugin:publishAllPublicationsToReposiliteRepository publishAllPublicationsToReposiliteRepository
```

Android SDK 源码采用本目录 `LICENSE` 中的 Apache-2.0。


## 性能与压缩协议（0.1.2）

升级采集 SDK 后，重新构建并安装业务应用的调试包。

- `hello` 声明 `gzip-json-v1` 时，新 macOS 客户端发送 `capture-gzip`。响应为 4 字节大端压缩长度 + 单个 gzip member，解压后仍为完整、以换行结尾的原始 JSON。桌面端支持运行时 SDK 0.1.3、0.1.4 和 0.1.5-SNAPSHOT、协议 1 和压缩采集能力。
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


### 悬浮窗选择

采集包含目标进程内可见的悬浮窗。窗口菜单从底层开始编号，最底层为窗口 1；默认预览前台窗口。其他进程的悬浮窗需要选择对应采集目标。
