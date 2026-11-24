# CompScope 的 Compose UI 运行时观测可行性

**建议把“选中一个组件，查看它当前有哪些 UI 状态，操作后哪些值发生了变化”作为首版目标。** 例如，项目样例已经验证点击后 ParameterCard 的 count 参数从 7 变为 8。桌面端可以先做状态面板与观测记录，树匹配负责把两次读数归到同一个组件实例。对于只存在于组件内部、没有传给子组件也没有暴露为语义的状态，需要另行验证 Debug SDK 的读取范围。

本文依据 2026-11-20 工作区源码、仓库既有真机记录及 Android 官方资料。没有新增真机测量。以下“已具备”表示当前实现或指定样例有证据；“待验证”表示仍需针对设备、宿主版本或具体字段验证。方案聚焦桌面应用及其结构化观测结果。

## 首版交互：观察组件状态

用户选中组件后，先列出该实例**确实读到的当前值**。用户可以关注其中一项，如开关的 ToggleableState，或业务 Composable 的布尔参数 expanded。再次采样时展示观测时间、上次值、本次值、来源及实例匹配依据。一次读取就能回答“现在是什么”；有第二次可信读数才能回答“与上次相比有无变化”。控件滚出视口、采集缺字段或匹配有歧义时中断记录，保留最后一次有效读数。

| 想知道的状态 | 现有能力与证据 | 面板应如何呈现 |
|---|---|---|
| 开关是否打开、行是否选中、输入框是否聚焦 | SDK 当前只专门处理部分交互字段。 | 显示具体语义及来源。保留 On/Off/Indeterminate 三态，未提供时显示未知 |
| 组件收到什么 UI 状态 | 示例的局部 count 通过参数传给 ParameterCard，示例验证已确认点击前后参数值 7 → 8。同理，expanded、isLoading 等若以可读参数传入，也可被选中观察 | 显示“ParameterCard · 参数 count · 7 → 8”。即使屏幕文字格式改变，仍可比较原始整数 |
| 组件内部的 remember 状态 | remember 可保存任意对象；mutableStateOf 等提供快照状态。当前采集器编码 Composable 参数，没有把任意局部变量名、状态实例和当前值关联起来。上例验证的是传出的数值；原始状态对象本身未被跟踪 | 只看到弹窗出现时可记录“弹窗出现”；没有直接证据时不生成“showDialog = true”这样的变量读数 |
| 明确指定的内部 UI 状态 | 可选 Debug 原型在持有 State 引用处登记标签、实例作用域与安全标量读取器。窗口打开时读初值，再按需观察，组件离开组合就注销。未暴露的局部引用若只能在 Composable 内取得，则需要改动该处 | 单独标记“已注册内部状态”，报告观察窗口及丢样；不能要求所有宿主改源码作为面板使用前提 |

**为什么公开的 Snapshot API 还差一步。** registerApplyObserver 能告知一次快照应用涉及哪些状态对象，回调没有源码变量名、所属组件和通用的旧值/新值。拿到已知引用后，可用 snapshotFlow 观察其标量读取结果；相等结果会合并，快速连续变化可能跳过中间值。这里仅观察已登记的 UI 状态，不订阅业务 Flow。若想评估“仅接 SDK、零 Composable 修改”，可用独立样例比较普通 remember、委托整数状态、共享或提升后的状态和同一调用点的多个实例。分别验证能否找到对象、读标量、定位实例、恢复源码名；每项独立记录覆盖率，匿名对象不能冒充具名状态。[样例源码](../android/sample/src/main/java/dev/composeinspect/sample/MainActivity.kt) · [示例验证](../android/validation/RESULTS.md) · [参数编码器](../android/compose-collector/src/main/java/dev/composeinspect/collector/ValueEncoder.kt) · [Snapshot API](https://developer.android.com/reference/kotlin/androidx/compose/runtime/snapshots/Snapshot) · [snapshotFlow 语义](https://developer.android.com/reference/kotlin/androidx/compose/runtime/package-summary)

## 1. 一次采集如何到达桌面

| 环节 | 当前行为及复用边界 |
|---|---|
| 目标与调度 | 桌面依据 ADB 设备序列号和包名连接目标应用的调试 SDK，读取组件树并截取屏幕。[采集入口](../macOS/Sources/ComposeInspectApp/DeviceSession.swift) |
| 已接 SDK 的应用 | debug 包的 Provider 自动初始化，检查 debuggable，启动本地 socket。桌面为一次采集建立 ADB forward，握手检查能力和 PID，支持时收 gzip。主线程遍历窗口、Composition 表，提取参数、布局与交互，服务线程编码并发送。服务可驻留；同次握手和采集共用 forward，各请求独立连接，结束移除 forward。下次仍握手。[Provider](../android/inspector-sdk/src/main/java/dev/composeinspect/sdk/InspectorInitProvider.kt) · [Collector](../android/compose-collector/src/main/java/dev/composeinspect/collector/ComposeCollector.kt) · [SDKInspectorClient](../macOS/Sources/ComposeInspectCore/SDKInspectorClient.swift) |
| 导入与工作区 | SDK 快照以 windows/root/children 组织展示节点，原始响应保留在采集信息中。SDK 先转换 Composition 分支并保留原始记录，不保证 Lazy 子表接回业务父节点。工作区管理当前快照、索引和显示投影；前后比较需要单独持有 A/B，不宜从过滤后的树反推原树。[导入器](../macOS/Sources/ComposeInspectCore/SnapshotImporter.swift) · [SDK 适配器](../macOS/Sources/ComposeInspectCore/SDKSnapshotImporter.swift) · [工作区](../macOS/Sources/ComposeInspectApp/WorkspaceStore.swift) |
| 源码定位 | 调用点有文件名、行号时可关联本地工程，SDK 原始数据还可含 offset、length、packageHash。本地按文件寻找候选，重名需要消歧。父级提供的锚点应标记继承。树上业务祖先能说明组合层级；异步业务调用栈、完整 Kotlin 调用链无法由此恢复。[源码导航](../macOS/Sources/ComposeInspectApp/SourceNavigationButton.swift) · [SDK 原始字段](../android/compose-collector/src/main/java/dev/composeinspect/collector/CaptureDtos.kt) |

**版本边界。** 仓库在 API 36 模拟器、分别对齐 tooling 的 Compose 1.10.6、1.12.1 示例上，验证了主页面、Dialog 和 Popup 的参数值及调用位置。inline 示例没有参数。这组验证检查参数和调用位置；样式与交互的覆盖范围见各自的测试记录。正式 release 的示例不含 SDK，常规不可调试包应仅预期系统对外暴露的无障碍信息；完整 Compose 参数、源码和调试计数仅针对满足调试条件的构建。混淆 debug、裁剪元数据、其他编译器版本、同一 AAR 跨宿主的表现均待验证。[验证记录](../android/validation/RESULTS.md) · [Android Studio 调试要求](https://developer.android.com/develop/ui/compose/tooling/debug)

## 2. 属性能观察到哪一层

| 目标 | 当前可用数据 | 比较时的解释 |
|---|---|---|
| text、字号、字重、行高、颜色、对齐 | 文本预览读取参数 text 或 AnnotatedString 的 text 成员；fontSize、fontWeight、lineHeight、color、textAlign 可从实际返回的参数或 TextStyle 成员读取。SDK 适配部分 TextUnit、Dp、sRGB Color | 保留单位及来源。Unspecified、缺失、截断须分开。字体回退、主题继承、绘制时着色及每段最终字形样式均不能保证解析 |
| bounds、宽高、padding、alignment | 树有边界；样式扩展可返回布局内外框、有序 padding 与局部坐标。宽高可由同一矩形得出，alignment 有时是调用参数 | 区分屏幕与窗口坐标、px 与 dp、测量边界与组合包装范围。对齐参数不能唯一解释实际位置 |
| enabled、selected、checked、focused、clickable | SDK 当前交互数据专门读取 OnClick、OnLongClick 和 Disabled，并保留采集错误 | 仅比较采到的交互字段。无点击动作、读取失败、后端未提供是不同结果，SDK 的 disabled 标记不足以证明任意节点都可操作 |
| visible、alpha、background、clip | 可比较与视口相交的边界，以及已解析的背景色、背景 alpha、形状和 clip 顺序。支持的圆角可结合尺寸、方向和密度求值 | 背景层 alpha 不能推出整个组件的最终透明度。祖先裁剪、窗口遮盖、graphicsLayer、自定义绘制会影响可见像素；可见性宜输出“几何相交/未知” |
| 图片 | contentDescription 在调用参数中可见时可读；布局尺寸可测；contentScale 是条件可得的调用参数 | 区分描述缺失、装饰图显式 null，以及后端未采集。布局尺寸不能推出资源原始尺寸或实际裁剪像素 |
| 组件与 Modifier | SDK 记录名称、调用点和组合树中的父子关系。样式扩展识别部分 padding/background/clip 及未知绘制类型；多个 Composable 可共享一个 LayoutNode | 返回有序层、实际关联依据与 unsupported。没有唯一关联时只比较原始节点边界。无法通用还原任意 Modifier、Canvas 或最终渲染 |

属性投影建议仅选 UI 展示字段。对每个值记录字段路径、命名空间、单位和可用性；未知值不生成确定变化。完整 Inspector 参数可能包含普通对象，观测报告不展开业务对象，也不追读 ViewModel、Flow 或存储层。当前分层样式真机/模拟器证据、SDK 交互的准确字段及文本回退策略分别见[样式验证](component-style-preview.md)、[LayoutInteractions](../android/compose-collector/src/main/java/dev/composeinspect/collector/LayoutInteractions.kt)、[TextComponentPreview](../macOS/Sources/ComposeInspectCore/TextComponentPreview.swift) 和 [Compose Semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics)。

## 3. 功能可行性与技术选择

| 功能 / 判定 | 推荐依赖及官方支持 | 改动、侵入性与成本 | 主要风险 |
|---|---|---|---|
| 已有属性直接读取，统一属性视图需要扩展 | SDK 采集的 Compose 参数与交互语义 | 桌面 Core 增加字段投影，低难度；设备新增成本为零 | 不同 SDK 和 Compose 版本的可用字段有所不同 |
| 离线 UI Diff 可直接基于已有快照开发 | 桌面节点模型；匹配器由项目实现 | 桌面 Core 与工作区持有 A/B，中等；无设备改动 | 重复子树误配、跨窗口误配 |
| 点击前后验证需要扩展 | ADB 操作、可选官方 UI Automator，复用现有 Inspector | 桌面编排，中等；已接入 SDK 的目标应用无需额外改动。前后各一次完整采集往往是主要成本 | 过期坐标、异步更新、SDK 采集失败 |
| 可见列表摘要需要扩展；精确元数据有条件需要 SDK | 现有几何、语义；有应用内 state 引用时使用公开 layoutInfo | 近似摘要改桌面，低至中；精确模式需要宿主暴露引用或扩展 SDK，中至高 | 预取、复用及未拼接的子表 |
| 重组次数、跳过次数仅列为研究项 | Studio 官方可展示；本项目缺少连续计数通路 | 需研究特定 inspector 协议及计数开关，成本高，追踪开销待测 | 节点寿命、重置、版本变化 |
| 动画表现可稀疏采样；通用动画状态暂不可行 | 主机对可信配对的 bounds 和已知属性取时间序列 | 桌面扩展，中等；成本随采样次数增长 | 漏掉短动画、纯绘制动画不可见、采集扰动 |

技术路线取舍如下。

- **ADB 与 UI Automator**适合执行操作和等待可访问目标。ADB 坐标点击可复用现有设备通道。使用 UI Automator API 通常要部署测试 instrumentation/runner，但目标应用可以不链接 SDK；外部自动化只看到无障碍投影。[官方 UI Automator 指南](https://developer.android.com/training/testing/other-components/ui-automator)
- **现有 Debug SDK**适合宿主已经接入且需要低带宽结构化采集的场景。可扩展能力协商、字段掩码和窗口选择。省去完整外部工具启动不等于保证采集快，主线程仍须遍历。新增精确列表状态若要求宿主注册 state，应作为显式可选能力。
- **Kotlin 编译插件**能够给已编译的调用点插入标识与计数，但要求重编宿主、跟进编译器变更；按调用点计数仍无法区分列表实例，计数语义还受内联和跳过影响。上述基础功能均不依赖此路线，投入高。
- **Compose Runtime 内部接口**可在限定 tooling/运行时组合下获得额外信息，宿主接入或 Inspector 适配均需按版本回归。保留当前已验证的窄适配与降级诊断。为读取任意状态而反射扫描对象、拦截重组或动画的通用方案不采用。

## 4. 两棵树怎样比较

**身份范围。** snapshot UUID 加窗口内 JSON Pointer 可引用某次采样中的节点。路径中的子序号会随插入而变；同一行 Composable 也可能实例化数百次。SDK 导入时分配数字 ID，其 layoutIdentity 来自对象的 identityHashCode，有碰撞、复用及进程寿命限制。现有分支几何键用于树内组织，缺少跨时刻唯一性。现有模型足以实现保守匹配，尚无通用稳定 ID。[模型](../macOS/Sources/ComposeInspectCore/Models.swift) · [SDK 转换](../macOS/Sources/ComposeInspectCore/SDKSnapshotImporter.swift) · [设备端身份来源](../android/compose-collector/src/main/java/dev/composeinspect/collector/ComposeCollector.kt)

1. **先限定可比范围。** 记录两次采样时间段、设备、包、SDK 版本、窗口/显示屏、方向、密度、采集能力。进程重启使运行时身份失效。窗口按宿主和可验证的窗口特征一一配对；同类弹窗无法区分时整窗标歧义。跨构建比较允许行号漂移，但降低其权重。
2. **先强后弱，逐父节点配对。** 在同一列表内使用已验证唯一且同类型的显式 item key，或在作用域内两端唯一的 testTag/资源 ID。检查节点类型和上下文是否冲突。再在已匹配父级下按调用点、类型、稳定语义角色和子树形状建立候选桶。文本、相邻已匹配节点、几何与顺序仅作辅助，否则待检测的文本变化或滚动本身就会打断配对。
3. **置信度表达证据。** 高＝唯一强锚且上下文相容；中＝无强键，但双向唯一，且调用点、父链和结构等多项证据一致；低＝只有序号、位置、可变文本，或存在同等候选。每个节点至多配对一次；歧义桶直接输出候选及原因。自动验证只用高置信变化，中置信单列供复核。可以先分桶近线性扫描，给大重复桶设候选上限；不在整棵树上两两打分。
4. **按来源比较值。** 配对后比较文本、属性、交互、位置及尺寸；先统一密度与坐标系，按字段设置容差（试用 1 px，保留原值）。整棵子树同向位移可折叠为父级移动并保留子级明细。忽略采集时间、临时 ID 等噪声；窗口过滤、显隐规则须两侧一致。缺失、null、显式 false、截断及不支持要分开。
5. **报告未配对原因。** 窗口/子树覆盖完整且没有竞争候选才报告观测树中的新增或移除。Lazy 场景用“进入/离开视口”；AnimatedVisibility 过渡或分页占位切换可见新旧分支重叠，只报告采样时观察到的结构。出现重复行、覆盖不全或超时，输出 unresolved/partial。不会仅凭树上消失断言业务数据已删除。

建议的桌面报告记录如下。before/after 是快照内引用；保留原值和匹配证据后，AI 可验证变化，也能回到两个源码上下文。此例为设计样例。

```json
{
  "status": "comparable",
  "beforeSnapshot": "A",
  "afterSnapshot": "B",
  "changes": [{
    "kind": "textChanged",
    "before": "/windows/0/root/children/2",
    "after": "/windows/0/root/children/3",
    "field": "parameters.text",
    "oldValue": "116",
    "newValue": "115",
    "confidence": "high",
    "evidence": ["sameWindow", "uniqueItemKey:remaining_count", "sameType"]
  }],
  "unresolved": []
}
```

验收样例应覆盖静态 A/A、计数变化、同名同文本兄弟、无 key 列表头插、滚动复用、遮罩窗口、动画过渡、整屏位移、SDK 采集能力变化。分别统计高置信误配率、匹配覆盖率和未决数；故意构造无法区分的两个相同行，预期输出未决。A/A 应无变化，头插不应引发全列表文本替换。

## 5. 操作追踪、列表与时间维度

**一次点击。** 在 A 中由用户或验证任务指定目标及可观察的后置条件，例如“剩余数变为 115”。优先在当前前台窗口按唯一描述、文本或已暴露的资源 ID 重新定位；Compose 的 testTag 要在对应子树启用 testTagsAsResourceId 才能作为 UI Automator 资源 ID 使用。若应用没有此设置，仍可从 Inspector 读语义；Inspector 节点编号不能直接交给 UI Automator。基础版可在单显示屏、同方向、无遮挡且最近确认的可点击目标内，通过 ADB 点击一次。取不到可信坐标、弹窗遮挡或目标歧义时终止操作。点击后采集失败可重读状态，不能自动重复点击。[Compose 与 UI Automator 互操作](https://developer.android.com/develop/ui/compose/testing/interoperability)

**等待与结果。** 优先等待后置条件。缺少指定条件时，可用轻量无障碍树观察目标子树的文本、动作与布局摘要；连续两次相同只说明该观察窗口内一致。建议初始间隔 500 ms、空闲时退避至 2 s、总预算 20 s，均作为待测配置。串行采样，预算覆盖完整读取；慢后端预留最终 B 的耗时，超出预算就报告超时与最后一次证据。持续动画可屏蔽事先声明的易变子树，保留屏蔽范围；异步请求可能在静默窗口后返回，目标条件未满足时不能宣布操作验证通过。最终只需一次完整 B 并在桌面计算 Diff。分别记录操作已发出、条件已满足、观察窗口稳定、超时或断连。[官方等待语义](https://developer.android.com/training/testing/other-components/ui-automator)

| LazyColumn / LazyRow / LazyVerticalGrid | 当前 SDK 可得 | 有状态引用时可选增强 |
|---|---|---|
| 当前 item、bounds、视口 | SDK 有已组合节点及其边界。仅对能识别的 item 根与列表视口求交，区分完整/部分相交；预取、超出裁剪区、跨窗口或无布局包装均需处理 | 公开 layoutInfo.visibleItemsInfo 与 viewportStartOffset/EndOffset；list 提供主轴 offset/size，grid 提供二维位置/尺寸。转换为屏幕边界还需列表原点、方向、padding 等 |
| index、key | 可读取偶然公开的调用参数或集合语义；样例的业务 index 只是该样例证据。可见序号不能推出全局 index，没有来源的 key 应留空 | LazyListState / LazyGridState 可提供可见 item 的 index、key。区分显式业务 key 与默认位置 key，未知类型不可当作可序列化业务 ID |
| 可滚动方向、偏移 | 有滚动动作/轴范围时可给语义级提示；语义范围和估算值不保证精确像素，反向布局需处理 | 状态引用可读 canScrollForward/Backward、firstVisibleItemIndex 和 firstVisibleItemScrollOffset。后者是相对首项的偏移，不是任意变高列表的全内容累计像素 |

公开 API 需要可信的列表 state 引用。仓库尚无通用的实例到 state 对应关系；单纯添加 SDK 依赖不会自动消除这一限制。Paging3 仅比较当前窗口中可见项、占位和文本。样例 100 项中仅采到 5 个已组合子项，不能由此恢复未加载数据、数据库 ID 或底层插删。[模拟器验证](../android/validation/RESULTS.md) · [LazyListLayoutInfo](https://developer.android.com/reference/kotlin/androidx/compose/foundation/lazy/LazyListLayoutInfo) · [LazyGridLayoutInfo](https://developer.android.com/reference/kotlin/androidx/compose/foundation/lazy/grid/LazyGridLayoutInfo)

**重组。** Studio Layout Inspector 支持 composition/skip 计数及重置，官方给出的条件为 API 29+、Compose 1.2.0+。当前 SDK 快照没有导入这些计数；同值可以反复重组，树变化也可能来自布局或滚动。未确认有适合本项目、跨版本且公开稳定的外部逐节点计数接口。研究原型须在同一存活会话中记录基线、结束计数与单调时钟，用计数差除以窗口时长求频率；节点替换、计数重置或断连则中断序列。次数高不能单独判定浪费。先与 Studio 对照，再测启用/关闭时帧耗差。仅为此功能引入编译插桩的收益有限。[官方重组调试](https://developer.android.com/develop/ui/compose/tooling/debug)

**动画。** 可报告带实际时间戳的位移、尺寸或已知样式值变化，标记采样间隔和漏采。即使多帧变化也可能由滚动、输入或异步布局引起；反过来，纯绘制动画可能没有结构变化。Studio Animation Preview 面向预览中受支持的动画 API，未提供可直接用于任意已运行应用的通用动画枚举入口。仅在轻量采集通过基准后尝试固定目标间隔，前一轮未完成就跳过本轮；不承诺逐帧、准确起止时间或运行中动画标志。[官方 Animation Preview](https://developer.android.com/develop/ui/compose/tooling/animation-preview)

## 6. 性能证据与验证门槛


SDK 已记录 mainThreadQueueMs、collectMs、stylesMs、treeMs、parameterExtractionMs。参数计时包含于树阶段，不能叠加；JSON 编码、gzip、socket 发送发生在返回主线程采集结果后。客户端已有读取、截图与解析重叠、建树的墙钟信息。低端设备主线程遍历和反射可造成掉帧；gzip 的 CPU 换带宽效果取决于负载。当前没有足以给低端机承诺刷新率的端到端数据。[SDK 客户端](../macOS/Sources/ComposeInspectCore/SDKInspectorClient.swift) · [设备服务](../android/inspector-sdk/src/main/java/dev/composeinspect/sdk/InspectorInitProvider.kt)

**建议的轻量路径。** 第一步直接比较已保存的 A/B，新增设备耗时为零。跟踪时复用未过期基线，等待期间只读目标的轻量语义；结束才取完整树。若开发结构化专用采集，需要让导入器从显示屏/窗口信息获得坐标上下文，解除现有入口对截图尺寸的依赖。SDK 可协商仅返回几何、名称与少量 UI 语义，并在设备端跳过深参数、样式反射与截图；桌面端丢字段只节省后续解析。会话绑定 serial/package/PID，断开或目标变化即失效。

| 基准场景 | 重点对照 |
|---|---|
| 小型静态页面 | 空闲无操作、相同树重复采集，分离启动、建连及固定开销；A/A 误报数 |
| 大型 Compose 页面 | 节点数、参数深度、未压缩/压缩字节，完整与轻量模式的时间和内存 |
| 长列表与分页占位 | 静止、滚动、头部插入；比较视口识别、重复项未决率和主线程帧耗 |
| 持续动画与延迟加载 | 超时、误判稳定、实际采样间隔、漏采率；对照完全不采集的运行 |
| 低性能真机 | 在同一设备重复上述场景；记录 API、Compose/compiler、构建、刷新率、温度、USB/无线 ADB 和 SDK 版本 |

每个组合建议冷启至少 5 轮、同进程热采至少 20 轮，报告样本数、中位数、P95 和失败数；冷启记录目标进程和主机工具的状态。比较有无截图、参数、gzip以及未来的持久会话，固定页面并核对输出语义。设备单调时钟分别围住主线程排队、遍历、编码、压缩与写出；主机测启动、读取字节、解压、解析、建索引和离线 Diff。分端记录，避免用不同时钟时间戳相减；用固定载荷回放估计传输/解析成本，记录 Perfetto 帧时间及掉帧，相同交互无观测作对照。放行标准应由最低支持设备的实测预算确定，测完前保持按需、单请求在途。

## 7. 实施顺序与交付判断

以下为单人熟悉项目的工程估算，包含针对性测试，排期取决于真机可用性。

| 阶段 | 任务、依赖与验收 | 工作量 |
|---|---|---|
| 1. 固定样本及基准 | 通过 SDK 采集静态、滚动、弹窗样本；记录版本、采集覆盖、耗时。先确认现有证据适用于目标低端机 | 2–4 人日 |
| 2. 组件状态面板与状态读数比较 | 从语义和命名参数投影当前状态，支持关注单一字段；复用前后快照做实例匹配并显示变化和缺测；验收 A/A、列表歧义、跨后端隔离 | 4–7 人日 |
| 3. 属性与可见列表摘要 | 基于阶段 2 补齐值来源、单位、交互和视口；验证两种语义、共有布局、裁剪与默认 key，输出未知原因 | 3–5 人日 |
| 4. 单次操作验证 | 依赖 2 的可信定位及 1 的时间预算；加入目标复核、一次点击、条件等待、超时和 B；在慢设备上核对误点与重复执行 | 4–7 人日 |
| 5. 定向研究 | 仅在基准显示收益后试轻量会话或有引用的 list/grid state；每项先用 2–4 人日验证一个宿主及一个对照版本，再决定产品投入 | 每项 2–4 人日原型 |

优先交付组件状态面板，用已有样例验收“选中 ParameterCard 即可看到 count = 7，点击后再次观察显示 8，来源为组件参数”。内部状态单独以没有向下传参、没有语义输出的局部布尔值做原型，检验能否读到真实值。第二优先是可见列表与样式的来源说明。精确列表状态按宿主选择接入；重组计数保留为版本限定的研究项。通用动画识别、任意 Modifier 最终像素还原、无键列表的强制身份匹配，以及低端机默认高频完整采集，均不纳入首版。
