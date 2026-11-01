# ADB 与完整 JSON 接入

日期：2026-11-01。实现位于 `macOS/`，接入工作区现有 ui-inspector JAR。

当前产品仅保留本次抓取的内存数据：新抓取成功或切换目标会清空旧问题，重启不恢复历史；导入与示例入口已移除。下文的原文保留/归档表示核心模型的无损能力及用户主动导出，不代表自动保存会话。布局和工具配置仍独立保存。

## 运行与采集

ADB、Java 默认按应用进程环境解析，手动配置优先；不执行 shell launcher，不覆盖成项目内的 JBR/ADB。Xcode target 和打包脚本均将现有 `ui-inspector.jar` 放入 App Resources，也可在 `⌘, → 检查` 指定其他 JAR。缺少 JAR 不触发构建。当前 JAR 的实际抓取需要 Java 25+，仅运行 CLI `--version` 无法验证这一点。

真实流程为：ADB 设备列表 → 全部安装包/前台包名 → `java -jar … dump-ui` → 截图 → 第二轮树与截图 → 完整解析 → 一起发布。无 shell 字符串拼接，参数通过数组传递，PNG 使用二进制文件接收。`adb shell -T screencap -p` 使用无 PTY 的 shell v2，把远端 stderr 与 PNG 分开；部分系统的 `exec-out` 会将显示屏警告混进 PNG，不能直接使用。

设备离线/未授权、Java 不兼容、上游失败、非法 JSON、截图失败均显式报错，保留上次完整快照。单个 inspector 进程上限 180 秒，ADB 默认 30 秒；可以取消，终止自己启动的进程，不执行全局 kill。

默认请求 `attributes,semantics,system-composables`，包含系统 Compose 节点和两种语义。`resolution-stack` 可在设置中显式开启：上游可能持久写入设备调试开关并重启 Activity，不能作为无副作用的默认选项。所有实际返回的内容均完整保留，未请求或上游没有返回的数据不会被伪造。

## 两层数据，原文不丢

`InspectorDocument` 保存完整 `originalJSON: Data`，归档和完整导出使用原始字节；空白、字段顺序、重复键、数字拼写和未知字段均可原样恢复。另用 `InspectorJSON` 递归解析为对象、数组、字符串、数字、布尔和 null。数字保存原始 token，不经过 Double，Int64 节点 ID 不丢精度，大整数和长小数也不舍入。对象语义视图遇到重复键采用最后一个值，原文仍包含全部重复项。

`SnapshotImporter` 只派生树、bounds、参数选择等 UI 需要的数据，派生列表不替代完整文档。完整 JSON 面板可切换节点、所属窗口、全部原文、采集信息、基线树和后续参数读取；支持复制与 JSON 导出。选中参数旁的 `{}` 可查看该参数完整结构。

| 范围 | 保留与展示方式 |
| --- | --- |
| 根对象 | `windows`、`displays` 及任何额外字段全部递归保存 |
| 所有窗口 | 每个窗口及其 `root`，配置、主题与未知窗口字段；节点可追溯所属窗口 |
| 所有显示屏 | ID、尺寸、方向及额外信息；多显示屏不丢 JSON，但图片关联尚未实现 |
| 配置与主题 | configuration 全部键值、theme 及其来源等结构，完整面板查看 |
| View / Compose / 未来类型 | 原始 type、ID、className、bounds、children、资源 ID、布局资源、源码位置及额外字段 |
| 四个参数命名空间 | parameters、attributes、mergedSemantics、unmergedSemantics 分开，名称相同不覆盖 |
| 参数递归 | elements 所有层级、无 value 的组、空集合、显式 null、isCollection、isTruncated、continuationToken |
| 属性来源 | directSource、styleChain 及其嵌套内容完整保留，不压成单一显示字符串 |
| 任意参数值 | 单位、颜色、资源、lambda 定位、对象/数组和未知类型原样保留；短值只是 UI 派生摘要 |
| 诊断与对照 | 两轮 inspector 日志、截图 stderr、时间、目标、实际 include、基线树原文和稳定性结果 |

节点以 JSON Pointer 定位，例如 `/windows/0/root/children/2`；与 snapshot UUID 组合绑定问题，避免不同窗口或重复 runtime ID 相互覆盖。原始 runtime ID 仅作展示/检查，不能当作源码锚点。

解析严格校验 UTF-8、JSON 语法和尾部垃圾；递归深度上限 512。根窗口结构、节点关键 ID/类型/名字/bounds 不完整时明确失败，不跳过节点后伪装成功。未知的非关键字段和节点类型保持兼容。bounds 为绘图转换成 Double，但原始值始终保留。

## 展示过滤

组件树默认隐藏已知 Compose 内部布局包装及 Text 的 BasicText 实现链，并把隐藏包装下的子组件提升到最近可见父组件；不整棵裁掉子树。规则结合节点类型、名称、来源文件及 Text 祖先判断，未知业务来源保持可见。树标题右侧过滤菜单可以恢复完整树。面包屑、线框和图片候选采用相同投影；缓存投影仅在切换快照或过滤模式时构建。完整解析、原始 JSON 导出、参数和问题的原始节点 ID 不受影响。旧问题若指向隐藏节点，定位时自动显示完整树。

## 截断参数继续读取

“完整解析”指无损保留 inspector 返回的 JSON，不代表 inspector 返回了所有运行时值。上游标记 `isTruncated` 的参数在 UI 明确显示，并可点击“继续读取”，将 opaque token 原样传给 `get-parameter`。

不自动递归追踪全部 token。续读会重新获取当前 UI，因此保存为独立 `ParameterRead`（组件路径、参数路径、token、读取时间、完整响应），可在原始 JSON 面板查看；不覆盖旧快照，也不把新数据悄悄加入原问题。导入、应用重启或切换目标后不直接复用旧 token。即使目标仍相同，也可能因页面变化导致 token 失效，失败原因如实展示。

## 图片与树的边界

比较两轮树的路径、类型、名字、bounds 和短标签，以及两张 PNG 的完整字节。全部一致且显示来源不歧义时自动启用近时关联；PNG 压缩差异、时钟或动画都可能保守地判为不稳定。当前没有逐像素容差/系统栏排除，也不声称原子同帧。

多逻辑显示屏禁用图片关联。实时抓取成功后直接展示并启用单逻辑显示屏的图片点选，不弹出确认框；即使近时校验未通过或 screencap 提示物理显示来源不明确，也保留原始稳定性结果与诊断供检查，不把它改写为校验通过。产品不再提供本地导入入口。多窗口手动切换，不推断 z-order。失败/取消不会混合新图片与旧组件树。

## 精简 AI 文本与验证

完整 JSON 在本地用于检查和归档；AI 复制仍只输出必要定位、用户勾选参数和问题描述，不附整棵树或整个 JSON，不要求标题。不调用 AI 或外部上传服务。

自动测试覆盖未知字段、全部配置、多个窗口/显示屏、Int64 极值、长小数、嵌套/空/null 参数、来源链、两种语义、token、归档字节一致、严格 JSON 拒绝、工具环境、进程超时/取消和已有问题工作流。

真实集成测试由 `COMPOSEINSPECT_LIVE=1` 启用，另需 `COMPOSEINSPECT_ADB`、`COMPOSEINSPECT_JAVA`、`COMPOSEINSPECT_JAR`、`COMPOSEINSPECT_SERIAL`、`COMPOSEINSPECT_PACKAGE`。可选 `COMPOSEINSPECT_LIVE_OUTPUT` 导出测试产物；执行 `swift test --package-path macOS --filter LiveInspectorTests`。已用 `emulator-5554` / 调试 Compose 应用抓取约 528 KB JSON、462 个节点，验证解析和归档原文一致。源码行号起算、复杂变换、受保护画面、物理/逻辑显示屏映射及正式签名分发仍需专项验证。
