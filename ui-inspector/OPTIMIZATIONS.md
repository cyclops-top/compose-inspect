# UI Inspector 本地优化与升级合并记录

本文件供维护者和 AI 在更新上游 UI Inspector 时逐项评估本地补丁。不能整目录覆盖新版，也不能仅因旧补丁存在就全部保留。

## Git 来源

| 项目 | 版本 |
| --- | --- |
| 上游仓库 | `https://android.googlesource.com/platform/tools/base` |
| 当前源码快照基线（见本目录 README） | `45628254f0f8a9bb3755d73f3d30ca78fbb2153d` |
| ComposeInspect 优化前基线 | `387950ac586e49e37ae2849cc0c11148443a2c6d` |
| 基线提交主题 | `Establish feature development baseline` |
| 本批修改日期 | 2026-11-02 |
| 本批优化提交 | 尚未提交；不要将优化前基线误当作优化提交 |

本批已通过增量源码构建生成新的 `lib/ui-inspector.jar` 并进行真机验证（见文末记录）；已将本批产物打包到 Release 版 macOS App 并安装到 `/Applications/ComposeInspect.app`。后续提交时，在下一次维护中补记实际提交哈希；也可用 `git log --oneline -- ui-inspector/OPTIMIZATIONS.md` 定位引入本记录的提交。禁止编造尚不存在的哈希。

## 观察与边界

设备 `GX202606000036WL`、应用 `cn.bs`、Compose 1.12.1，用户测得完整 CLI 抓取 46.211 秒、34.112 秒。只保留 `system-composables` 约减少 3 秒。上述是优化前的用户观测，不是可控基准。

ViewNodes 无条件调用自定义 ComposeStyles；删除 attributes/semantics 不会关闭这部分。ViewInspector 在应用主线程进行 View 和样式采集。样式路径逐个布局节点和 Modifier 反射取值，原来每次调用都扫描公开方法，并在筛选 Modifier 前计算坐标。本批针对这些确定存在的重复工作；尚无真机数据证明它是几十秒延迟的主要来源。

## 可独立选择的补丁

路径均相对 `vendor/android/tools/base/ui-inspector/`。

### PERF-001：采集内反射元数据缓存

- 文件：`agent/inspectors/view/src/main/java/com/android/tools/ui/inspector/inspectors/view/ComposeStyles.java`。
- 一个 AndroidComposeView 的采集创建一个适配器实例。按实际 Class 缓存公开方法数组，按方法逻辑名及参数数量缓存原先选中的 Method，按字段名缓存包含继承查找的 Field；缺失结果也缓存。
- 只缓存反射元数据，不缓存属性值、布局坐标或跨次采集状态。采集结束即释放，避免长期保留应用类加载器。不同 ClassLoader 下的 Class 不混用。
- 保留原有 Kotlin `-` / `$` 名称匹配及首个匹配行为；这不是新的重载解析器。如果新版改变匹配规则，按新版规则重做缓存键，不能直接移植旧键。
- 上游如果已移除本地样式扩展，先决定是否仍需该功能；如果已具备等效的安全缓存，舍弃此补丁。

### PERF-002：先筛选 Modifier，再计算坐标

- 同文件 `layer()`。先判断 padding/background/clip 或需报告的未知绘制类型，再进行 bounds 和 JSON 构造。
- 保留原先支持的类型、未知绘制/padding 诊断与四角坐标转换。无关类型不再访问坐标；其坐标读取失败也不再导致整个布局记录丢失。
- 不把四角计算替换成两角，不引入跨节点坐标缓存，以免破坏旋转/变换或动态值。
- 升级时与新版类型分支同步，不能用旧白名单提前丢弃新版支持的样式。

### OBS-001：CLI 分阶段单调时钟计时

- 文件：`core/src/main/java/com/android/tools/ui/inspector/Commands.kt`。
- 记录 Agent attach/reconnect、View inspector staging/connection、Compose inspector connection、View tree（含样式）、逐窗口 Compose tree 和 parameters 的开始、完成/失败及毫秒数。
- 使用 `System.nanoTime()`；沿用 PROGRESS 日志通道，不向 JSON stdout 添加内容。异常（包括取消）原样抛回，不重试、不吞掉。
- 计时是主机观察到的墙钟耗时，包含设备工作、传输及响应解析；不能把 View 阶段耗时全部归因于 ComposeStyles。窗口阶段包含窗口 ID，便于发现多窗口累计耗时。
- 如果新版已有等效计时，使用新版功能；如协议调用改变，重新选取边界。不要将可变缓存的窗口请求贸然并行化。

## 验证

新增 `tests/ComposeStylesPerformanceTest.java`：无关 Modifier 不访问坐标；未知绘制类型保留几何；Kotlin 风格方法名仍可读取；重复读取方法和继承私有字段返回新值；重复缺失字段继续正确失败。

`tests/run-compose-shapes.py` 支持 `JAVA_HOME` 和 `ANDROID_HOME`，仍默认使用项目内预编译工具。运行：

```sh
JAVA_HOME=/path/to/jdk ANDROID_HOME=/path/to/android-sdk \
  python3 ui-inspector/tests/run-compose-shapes.py
```

2026-11-02 验证通过：Java 编译、真实 Compose 1.12.1 的 8 组混合单位/方向形状测试、归一化/CircleShape/未知形状检查，以及新增回归测试。测试依赖本机 Gradle 缓存中的 Compose AAR、Kotlin 标准库、Android 36 SDK；JSON 测试运行库从 Maven 获取并校验发布的 SHA-1。

初始验证时缺少 `vendor/android/prebuilts`，未能执行完整 Bazel 构建。随后新增可重复增量构建入口，已完成 Kotlin CLI/Core、View Inspector Java/DEX 编译及真机验证，详见后文。完整 AOSP/Bazel/native 从零构建仍不在本次验证范围内。

恢复构建环境后：执行 `ui-inspector/build.sh`，运行新 JAR 在同设备、同 APK、同页面至少各测三次，分别记录首次和重复采集；比较完整 JSON 的节点、样式和诊断语义，并保留每阶段日志。确认当前 Agent 使用新产物，避免测到旧驻留实现。

## AI 升级流程

1. 记录目标上游提交、本地当前 HEAD 和干净基线；保留用户其他改动。
2. 对 PERF-001、PERF-002、OBS-001 分别判断：新版已解决、本地仍需、接口变化需重写、功能已不适用。给出源码证据与决定。
3. 用优化前基线对比本地历史，限定本文件列出的路径与补丁，不将其他兼容修改误算成本批优化。示例：`git diff 387950ac586e49e37ae2849cc0c11148443a2c6d <本批实际提交> -- ui-inspector/`；若中间混入其他提交，进一步限定提交和文件。
4. 保留参数值新鲜度、变换坐标、异常传播及 JSON 输出约束；按新版实现调整测试，完成完整构建和真机对比。
5. 在本文件追加目标上游/本地提交哈希、每项保留/舍弃/重写决定、测试命令和测量结果，不删除原记录。不自动提交或 push，遵循用户当次授权和提交代理规则。


## 2026-11-02：构建环境与真机验证

### 构建入口和复用边界

- `build.sh`：项目内 Bazel 不存在时进入 `build-standalone.py`；完整工作区仍走原 Bazel 分支。
- `standalone-build.lock.json`：固定基线 JAR、编译依赖 SHA-256，以及未重编的 common/protocol、payload、art-tooling 源码指纹。变动这些源码会拒绝增量构建，不能悄悄复用旧实现。
- 重编内容：全部 Kotlin Core/CLI；全部 Java View Inspector；View Inspector DEX 和资源。
- 复用内容：基线中的第三方库、生成的协议类、底层 Java payload/ART 工具/native Agent。为编译恢复 adblib 的 Kotlin package facade 索引，并在临时编译类路径中将 protobuf 类引用重定位至设备已有的隔离命名空间；不替换底层 protobuf 运行时。
- `bin/ui-inspector`：支持本机 Java/SDK 回退，修复此前缺失项目内 JBR 导致无法启动的问题。
- Java 27、Android 36 SDK/build-tools 36.0.0、Kotlin compiler 2.4.21。Java 编译目标 17，DEX min API 29。生成包仍依赖基线运行库的 Java 25+ 要求。
- inspection AAR 来自 AOSP prebuilts，Git blob 为 `2317fe6e7c5f72493608fff1730024263488f0bc`，实际 SHA-256 为 `d14ca9b2dfdc902758a5d6f9f060e95df4517971355cae1948bff3e913777443`。同目录 `.sha256` 附件与该 blob 不一致，因此锁定并核对 Git blob 和实际 SHA-256，不采用附件值。
- 构建成功后原子替换产物；JAR 内 `META-INF/composeinspect-build.json` 保存编译输入来源。

本次产物 `lib/ui-inspector.jar` SHA-256：

```text
20dd20f344c3827460e824be03dbfe80971312d48770cbae0caf5524fbcffdad
```

原始基线 JAR SHA-256：

```text
75e69ed3488b510eb798ba5e577f5d8ad1f93b8603bab5e27ea451c0353de5af
```

### 真机数据

设备 `GX202606000036WL`，应用 `cn.bs`，完整 facets `attributes,semantics,system-composables`。未重启目标应用。

| 顺序 | 包 | 总耗时 | 结果 |
| --- | --- | --- | --- |
| 1 | 原始基线 | 37.797 秒 | 成功 |
| 2 | 初步优化构建 | 10.993 秒 | 与第一次 JSON 字节一致 |
| 3 | 正式优化产物 | 10.454 秒 | 与第一次 JSON 字节一致 |
| 4 | 正式优化产物再次运行 | 6.224 秒 | 成功；参数值发生差异，不用于同内容提速比例 |
| 5 | 原始基线回测 | 36.629 秒 | 与第一次 JSON 字节一致 |

同内容的基线回测与正式优化产物相比，耗时减少约 71.5%。这是单设备、单页面观察，不能推广为所有设备/界面的固定提速幅度；新构建方式也属于实验变量。

同内容 JSON：1 个窗口、1230 个 ComposeNode、10 个 ViewNode，1,147,357 字节，SHA-256 `f7cbfe57de02463e1ec8bce0c8be867cbe9271aa9237456cf2ac864ba7976163`。样式字段也参与字节一致性比较。

正式优化产物第 1 次阶段耗时：Agent 903 ms、View staging 139 ms、View connection 55 ms、Compose connection 256 ms、View tree（含样式）1023 ms、Compose tree 1095 ms、Compose parameters 6299 ms。第 2 次参数阶段下降到 2922 ms，但参数输出有 27 处差异（例如 CombinedContext 与 Main、Map[0] 与 EmptyPersistentCompositionLocalMap），不能误称这次 JSON 完全相同。

本机原始记录保存在 `.build/standalone/comparison.json`、`optimized-1.log`、`optimized-2.log`、`baseline-control.log` 和对应 JSON；这些含应用 UI 数据的文件不提交 Git。`--version`、`dump-ui --help`、无 JAVA_HOME/ANDROID_HOME 的启动回退、shell 语法和 `git diff --check` 均通过。随后已执行 `BUILD_CONFIGURATION=release ./macOS/scripts/build-app.sh`，安装到 `/Applications/ComposeInspect.app`；`codesign --verify --deep --strict` 通过，安装包内 JAR 的 SHA-256 与上述正式优化产物一致。
