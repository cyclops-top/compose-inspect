# debugImplementation 能力验证结果

日期：2026-11-02。设备：BSPAD / Android 14（API 34）。工程：AGP 9.2.1、Gradle 9.4.1、Kotlin/Compose compiler 2.4.21。

**结论：业务只加 `debugImplementation`，可以获取本示例中 ui-inspector 返回的全部 Compose 节点及其调用位置，也能读取同名参数。当前 SDK 仍不是完整 inspector 替代品：跨 Composition 表拼接、复杂类型渲染、回调位置、语义与 View 混合树尚有差距。**

## 验证方法

- 同一份 `sample/src/main/` 分别构建 SDK debug、无 SDK debug、无 SDK release；业务源码和 Manifest 不变。
- SDK 包仅通过 Manifest 自动初始化，采集阶段不运行 ui-inspector；无 SDK 包通过当前项目已有 JAR 采集。
- 主页面、Dialog、Popup 每个场景分别 force-stop 后冷启动，避免先前 inspector 注入影响 SDK 结果。
- 两端分别保存原始 JSON。节点按 `(名称, 文件名, tooling 行号)` 做 multiset 对照；参数另按 `(节点键, 参数名)` 对照。
- SDK 结果另断言具体参数值、对象字段、默认值、源码行和 UTF-16 offset；真实点击后断言 count 从 7 变成 8。
- 检查 APK DEX/Manifest，确认无 SDK debug/release 不含 SDK 初始化类、采集类及 `ui-tooling-data` 类。
- 检查 Gradle 实际解析依赖，确认每个测试组合中 SDK 未提升宿主已有 Compose 依赖版本。

脚本：[validate.py](../tools/validate.py)、[compare.py](../tools/compare.py)。精简机器证据（含源码/APK/JAR SHA-256）：[results.json](results.json)。完整 JSON、APK 和构建日志位于被 gitignore 的 `../artifacts/<版本>/`。

## 节点、位置与参数名覆盖

两个版本都成功完成三种场景的 SDK 与 ui-inspector 真机采集：

| Compose | 场景 | SDK 原始有名组数 | inspector Compose 节点 | 匹配的 inspector 节点 | 匹配的 inspector 参数名 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1.12.1 | 主页面 | 398 | 105 | 105 / 105 | 275 / 275 |
| 1.12.1 | Dialog | 450 | 113 | 113 / 113 | 291 / 291 |
| 1.12.1 | Popup | 468 | 114 | 114 / 114 | 295 / 295 |
| 1.10.6 | 主页面 | 414 | 105 | 105 / 105 | 275 / 275 |
| 1.10.6 | Dialog | 487 | 113 | 113 / 113 | 291 / 291 |
| 1.10.6 | Popup | 505 | 114 | 114 / 114 | 295 / 295 |

这里的“全部”只针对这份 fixture 的 inspector 输出，不是所有应用的能力保证。SDK 原始组更多是因为保留运行时包装组，不能解释为 SDK 比 inspector 更完整。参数名全匹配也不等于所有值都已转换成可读形式。

主页面包含 1 个主 Composition 和 5 个 Lazy item 子 Composition。SDK 能拿到当前已组合的 5 个 `LazyRowProbe`，不会读取尚未组合的其余 95 项。Dialog/Popup 分别新增独立窗口和 Composition。

## 按能力比较

| 能力 / fixture | SDK 实测 | 当前 ui-inspector 实测 | 差距判断 |
| --- | --- | --- | --- |
| 普通函数、无布局包装函数 | 名称、子节点、位置、参数可见 | 可见 | 原始数据入口可用 |
| `InlineWrapper` | 节点和调用位置可见，参数为空 | 同样无参数 | 本 fixture 上两端共同限制 |
| `NonRestartableCard` | 节点和调用位置可见，参数为空 | 同样无参数 | 本 fixture 上两端共同限制 |
| Lazy item | 节点、index/label、位置可见；分属独立表 | 已拼入主树 | SDK 尚缺跨表父子关系拼接 |
| Dialog / Popup | 独立窗口可见，内容参数和位置可见 | 可见 | API 34 测试通过；旧系统尚未验证 |
| 字符串、Int、Boolean、null | 具体值校验通过 | 同值可见 | 无已发现差距 |
| 默认参数 | 值可见，额外保留 `fromDefault` | 值可见 | SDK 可正确读取默认值 |
| Profile 对象 + List | name/age/tags 值校验通过 | 同值可见 | 通用对象仍需更多类型验证 |
| Dp / Color | 原始 Float/Long + inlineClass | `12 DP`、`#FFFF0000` | 缺专用格式化适配器，原始值已拿到 |
| 回调 `onClick` | 对象类型，标记 opaque | 文件名与回调行号 | 缺 lambda 源码解析 |
| Modifier / TextStyle 等 | 类型保留，多数标记 opaque | 展开为可读属性 | 缺类型渲染器及属性提取 |
| 调用源码位置 | 文件名、行、offset/length、包 hash | 文件名和行号 | SDK 调用点已通过源码校验；两端都不是完整项目路径 |
| 重组后参数 | 点击后 count 7 → 8，通过断言 | 本轮未单独做重组基准 | SDK 不只读取首次状态 |
| View 混合树与语义 | 当前采集器未实现 | AndroidView 内 TextView、merged/unmerged semantics 可见 | 后续功能范围 |
| 大参数续读 | 固定限深/限长，明确截断，无续读 | 现有协议支持 continuation token；本轮未专项续读 | 后续协议和实现范围 |

具体结构差异：SDK 的 `LazyRowProbe.businessAncestors` 为空，因为它是独立表的根分支；inspector 的对应业务祖先是 `ProbeScreen`。因此当前结果**还不能称为统一的完整 Compose 树**。Dialog 和 Popup 在两端都按各自窗口表示，不能简单按 Activity 根强行合并。

行号细节：tooling 的 `SourceLocation` 注释仍描述为 0 起算，但实测运行时 parser 已将编码行号加 1。SDK 保留原值；`MainActivity.kt` 的调用行与 offset 都通过检查。不能再机械地 `+1`。

## 版本结论

**不必限定为唯一 Compose 版本。** 本轮相同采集源码分别用 1.10.6 与 1.12.1 的依赖构建，两个组合都成功。两者共享的业务能力结果一致，运行时内部组数量不同。

范围仍需明确：

- 这是两个**分别构建并对齐 tooling**的组合，不是同一份已发布 AAR 跨版本的二进制兼容测试。
- SDK 依赖 `ui-tooling-data`。当前 project 默认 1.12.1；旧业务接入时必须先对齐 `composeVersion`，否则 Gradle 可能提升业务依赖。
- 正式 SDK 应以最低支持版本编译，再测试同一二进制与不同宿主 Compose/tooling 的组合，检查初始化、参数和源码解析分别是否可用。Kotlin compiler 版本也是矩阵维度，不能只看 Compose 版本。
- 未验证其他 Compose/Kotlin 组合、minified debug、多进程、特殊 Composition 宿主、API 26–28、多显示屏、状态恢复和性能开销。

## 交付与下一步

已交付四个 Android 模块、Gradle Wrapper、可独立运行的采集客户端、可复现的真机对照脚本。两个版本的 debug/release 构建、真机数据断言及 SDK/collector lint 通过（lint 在 1.10.6 配置下运行）。release 包未含 SDK 类、初始化 Manifest 或 tooling-data 类。

下一阶段优先做 Composition 子表拼接和参数类型适配，再对接现有 macOS 模型。应用发现、入口模式切换及正式发布不在本次验证工程内。
