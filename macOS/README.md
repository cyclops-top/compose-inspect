# CompScope macOS

原生 SwiftUI + AppKit 界面工程，最低 macOS 14，当前 Xcode App target 面向 Apple Silicon。无需第三方 Swift 依赖；Android `ui-inspector/` 仍独立构建；现有 JAR 随 App 打包，Java 与 ADB 使用设置解析出的本机工具。

## 使用 Xcode

打开 `ComposeInspect.xcodeproj`，选择 **CompScope → My Mac** 后运行。App target 通过本地 Swift Package 依赖 `ComposeInspectCore`，界面和核心逻辑共用同一份源码。

```sh
open macOS/ComposeInspect.xcodeproj
```

如果 Xcode 提示签名团队，先选择本机运行；工程使用本地 ad-hoc 签名，不需要开发者账号即可调试。正式分发签名、公证与 Intel 支持尚未配置。

## 命令行

在仓库根目录执行：

```sh
swift test --package-path macOS
./macOS/scripts/build-app.sh
open macOS/dist/CompScope.app
```

脚本默认生成本机 Release bundle，以启用 Swift 优化；开发调试可使用 `BUILD_CONFIGURATION=debug ./macOS/scripts/build-app.sh`。脚本使用 Swift Package executable `ComposeInspectLauncher`，打包后的应用仍为 `CompScope.app`。分开命名避免与 Xcode 原生 App scheme 冲突。

也可通过 Xcode 原生 target 构建：

```sh
xcodebuild -project macOS/ComposeInspect.xcodeproj \
  -scheme CompScope -configuration Debug \
  -derivedDataPath macOS/DerivedData CODE_SIGN_IDENTITY=- build
```

原生 target 构建产物位于 `macOS/DerivedData/Build/Products/Debug/CompScope.app`。核心测试通过 `swift test` 或 Xcode 的 ComposeInspectCore package scheme 执行。

应用图标源文件为 `Artwork/AppIcon.svg`，透明预览为 `Artwork/AppIcon.png`；两种打包方式均使用 `Configuration/AppIcon.icns`。修改 SVG 后执行 `./macOS/scripts/generate-app-icon.sh`，使用系统 WebKit 渲染并生成 16–1024px 的标准 macOS 图标，无需第三方工具。

## 当前会话工作方式

这是实时抓取辅助工具，只处理当前一次抓取结果：

- 启动为空白，选择在线设备和应用，点击右上角强调色相机抓取。
- 点击抓取即清空上一轮的问题、参数勾选和撤销记录。新截图、完整 JSON 与组件树成功后一起替换。抓取失败或取消时，画布保留上次成功的截图和组件树。
- 设备和应用菜单选择下次抓取的目标。
- 问题和采集内容只存在当前进程内存中，不自动写盘、不恢复历史；旧版工作区自动保存文件不再读取。没有导入、示例或历史入口。
- 布局尺寸、线框/节点过滤偏好和工具环境配置继续保存。

## 界面与问题列表

上方为组件树、截图、参数侧栏，下方为问题列表与描述/AI 文本预览；全部分栏可拖动并自动记忆尺寸。顶部检查区最小高度 260pt，底部最小 170pt，没有原来的 240pt 上限。窗口变小时按最小可用尺寸调整。

组件树固定单行，支持主轴锁定的上下/左右滚动；单击选择，双击展开/收起。选中后纵向确保整行可见；横向已可见则不移动，否则最小滚动并尽量保留 16pt 左侧间距。长名称优先露出开头。节点索引与普通边框缓存，高亮独立绘制，参数惰性布局。

搜索框下提供“精简”和“仅可点击”勾选项；仅可点击开启时自动勾选并锁定精简。精简旁的齿轮可以配置规则，默认隐藏 Compose 内部实现、常见 Android/AndroidX 布局、ViewStub 和 Compose 宿主；滚动容器预置但默认不勾选。支持逐项启用、添加/移除 View 类名以及恢复默认，修改立即生效并自动保存。隐藏节点的子组件提升显示，窗口根节点始终保留；树、面包屑、线框和点选候选同步使用筛选结果，原始 JSON 不删字段。

图片点选按命中面积从小到大排序，同面积优先更深层级；重复点击同一候选集合依次向外循环，最大后回到最小。

按 Esc 或点击截图外的空白区域取消当前组件选择，清除截图高亮、树选中和点选候选，已记录的问题保留。线框使用蓝色细实线和红色直角标记，接近 Android 调试布局边界；同一窗口内位置、尺寸完全相同的边框只绘制一次，重叠组件仍可独立点选。

截图右下角的工具栏提供缩放、适合窗口、拖拽、选择、取色、选择父组件和线框。重叠组件菜单在宽画布上与工具栏并排，在窄画布上移到工具栏上方。双指平移或拖拽到截图边缘时，留白最多约 1 厘米。若某个方向原本的留白已超过这个距离，截图在该方向保持居中。适合窗口和新抓取都会重置画布位置。

选中组件后输入非空描述即记录，一个组件对应一个问题。清空描述会移除该问题。点击问题可定位组件并恢复描述和参数。垃圾桶清空本轮问题后可点一次“撤销清空”，恢复原顺序、描述和参数勾选。编辑问题、更改勾选或开始新抓取后，撤销记录过期。

底部为问题列表、AI 定位文本预览和描述输入三栏。“复制全部 N 条”（⌘⇧C）复制本轮所有问题，“复制当前组件”（⌘⌥C）复制预览中的定位文本。分栏宽度保存在 `layout.split.*`。

## 实时抓取与完整 JSON

ADB 发现设备、列出应用并识别前台包名。默认在每次点击相机时定位前台 Activity，识别失败会提示。关闭“截图前自动获取前台应用”即可手动选择包名，包括其他应用的悬浮窗。页面稳定后再抓取，每次只读取一轮组件树和截图。优先使用应用内 SDK，回退到 ui-inspector 时需要 Java 25+。截图使用 `adb shell -T screencap -p` 分离远端警告和 PNG 字节。

成功后直接展示。单逻辑显示屏可点选，多个显示屏可通过组件树检查。显示屏警告和原始诊断可在采集信息中查看。

默认请求 `attributes,semantics,system-composables`。设置“检查”页可选择 JAR 或开启 `resolution-stack`；后者可能持久修改设备调试开关并重启 Activity，因此默认关闭。

JSON 完整递归解析，未知字段、大整数、长小数、空/null 参数、来源链、两种语义及 continuation token 均保留。原文在当前会话中保持字节不变，支持查看、复制与用户主动导出；截断参数显式续读，不自动递归追踪未知大小的集合。详见 [完整 JSON 接入说明](../docs/ui-inspector-json.md)。

### 工具环境设置

按 `⌘,` 打开设置。ADB 与 Java 路径默认留空，使用应用启动时继承的环境变量；填写路径后优先使用手动配置，不会在手动路径无效时悄悄切回其他版本。

| 工具 | 默认查找顺序 |
| --- | --- |
| ADB | `ADB` → `ADB_PATH` → `ANDROID_HOME/platform-tools/adb` → `ANDROID_SDK_ROOT/platform-tools/adb` → `PATH` 中的 `adb` |
| Java | `JAVA_HOME/bin/java` → `JDK_HOME/bin/java` → `PATH` 中的 `java` |

只选取存在且可执行的文件；自动候选无效则继续查找。手动 ADB 路径选择可执行文件；手动 Java 支持可执行文件、JAVA_HOME 目录及 `.jdk` 根目录，路径包含空格也可直接填写。设置中的恢复按钮清空对应手动路径，回到环境变量解析。

“检测”在后台运行 `adb version` 或 `java -version`，分别显示版本或失败原因，15 秒超时；仅找到文件不等于 Java 运行时可用（例如系统的 `/usr/bin/java` 启动器）。启动读取 shell 环境后自动检测 ADB、Java 和 JAR 是否就绪；工具缺失、无法运行或 Java 低于 25 时自动显示配置面板。面板可选择工具路径并重新检测，环境通过后可点击完成；也可稍后配置。设置中的 Java 检测同时检查抓取所需的最低版本。当前工作区 JAR 的实际抓取依赖 Java 25 编译的类，需要 Java 25 或更新版本；Java 24 即使通过 `--version` 也无法完成抓取，App 会明确提示版本不兼容。

App 启动时在后台运行用户 shell 的登录、交互配置（`-ilc`，zsh 会读取 `.zprofile` 和 `.zshrc`），补充 PATH、ADB、ADB_PATH、ANDROID_HOME、ANDROID_SDK_ROOT、JAVA_HOME 和 JDK_HOME，再发现设备。因此从 Finder 或启动台打开也能使用终端配置的工具路径。只导入上述工具变量，手动路径始终优先。设置中的“重新读取环境”会重新执行该读取，无需重启；最长等待 8 秒，失败时保留当前环境并在设置页显示原因。设置会显示实际解析路径与来源，仍支持手动选择。

工具设置保存在 UserDefaults 的 `toolchain.adbPath` / `toolchain.javaPath`。本设置用于 macOS App 工具环境，独立 CLI 的 `ui-inspector/bin/ui-inspector` 目前仍使用项目内置 JBR/ADB，尚未被设置界面改写。

## AI 修改文本

AI 预览底部显示当前生成文本及全部问题的预计 Token 数，随描述和勾选参数更新；全部统计包含复制时的编号和分隔符，空文本为 0。使用本地粗略估算（ASCII 约 4 字符/Token，非 ASCII 约 2 UTF-8 字节/Token），实际数量取决于目标模型的分词方式，无需联网。

AI 预览渲染 Markdown 标题、代码块和正文；复制按钮输出 Markdown 原文，用户填写的修改要求保持原样。

复制全部问题时，每项带组件路径、定位说明、所选参数和用户填写的修改要求。例如：

````markdown
## 组件路径
已省略包装组件，末项为目标。

```text
ReaderApp.kt:96 (SettingsScreen)
  → SettingsScreens.kt:43 (GlassCard)
  → SettingsScreens.kt:47 (SettingsRow)
  → GlassComponents.kt:106 (Text「关于」)
```

注：文件和行号为运行时采集的调用位置线索，请结合当前源码确认。

## 修改要求
将文字改为应用信息
````

组件路径从最近的 Screen 展开。缺少 Screen 时取最近三个有源码的非包装祖先。箭头表示采集的嵌套关系，行号来自运行时。关联 Android 工程后，可把匹配的调用位置定位到工程内文件。文本在本地生成，包含目标、勾选参数和用户描述。

## 验证

`swift test --package-path macOS` 覆盖核心解析、定位、点选、布局恢复及当前会话替换/删除行为。真实设备测试默认跳过；设置 `COMPOSEINSPECT_LIVE=1` 及 `COMPOSEINSPECT_ADB/JAVA/JAR/SERIAL/PACKAGE` 可显式执行。

Core 中的 JSON 归档、导入适配和示例 fixture 用于兼容性与测试，macOS 产品界面不提供导入/示例，也不调用工作区历史持久化。

组件分层样式和外框采集说明见 [component-style-preview.md](../docs/component-style-preview.md)。

右栏按选中组件展示已解析的主要属性。文本优先显示内容、字号、字重和文字颜色；按钮和卡片优先显示自身背景和圆角；布局优先显示尺寸和内边距。多层背景可展开逐层查看。「更多属性」初始收起，切换组件时沿用当前的展开或收起状态。展开后可查看所选组件的源码线索、文本与分层样式预览、坐标及资源，并勾选要提供给 AI 的参数。

圆角样式关联：内容边界相同但样式不同的记录，不再一律丢弃。仅在节点自身的原始 Shape 语义（或直接 shape 参数）与实测圆角一致、且候选结果唯一时解除歧义；合并语义不能作为证据，避免把子组件或外层 padding 的样式误赋给当前节点。支持当前采集格式的 dp 圆角和 CircleShape，无法确认时仍显示未知。

### 快速定位源码

右栏组件名旁的组合按钮提供源码操作。通过“文件 → 打开 Android 工程”关联项目后，点击左侧 Android Studio 图标可直接打开调用处。右侧下拉菜单提供「打开」和「复制」；有源码位置时即可复制文件名及行号，如 `LoginScreen.kt:86`。优先选择当前组件或最近祖先中能唯一匹配的工程文件。多个候选需要手动选择。

### 快速交给 AI 定位代码

选中截图或组件树中的节点，即可点击“复制当前组件”或按 `⌘⌥C`。问题描述可选，仅勾选的参数进入复制文本。关联 Android 工程后，源码跳转和 AI 文本优先使用同一处能唯一匹配的工程相对路径，同时注明组件自身采集到的位置。

源码线索区分自身采集位置、祖先位置和缺失位置；采集位置不是已验证的函数声明，无效行号不会作为精确位置输出。AI 定位文本不附带应用包名、同名实例序号、快照节点路径或窗口编号；保留组件路径、源码线索、资源信息及勾选参数。

鼠标移过截图时可预览组件边界。点击后，画布高亮所选组件，右栏显示组件名称和属性。可以从重叠候选菜单直接选择，或用左右箭头 / `⌘⌥[`、`⌘⌥]` 循环切换。`⌘⌥↑` 选择当前展示树中的父组件；普通树选择会清除上一个点位的候选。`⌘⇧C` 仍用于复制全部已记录问题，普通 `⌘C` 保持文本复制行为。


## 统一采集模型

两种后端都通过适配器生成 `SnapshotTreeInput`，再由唯一的 `SnapshotImporter` 建树，输出 `InspectorSnapshot / InspectorNode / ComponentStyle`。组件树、筛选、点选、参数区和样式预览只使用这一套模型。

- `UIInspectorSnapshotAdapter` 解码 ui-inspector 的样式扩展属性，并记录需要隐藏的传输属性路径。
- `SDKSnapshotImporter` 适配窗口偏移、调用树、参数值和 host 样式目录，保留 SDK 原始响应。
- `SnapshotTreeInput` 提供公共节点字段、按节点路径索引的已解码样式目录和隐藏属性路径；公共建树器不识别任何后端专属样式字段。
- `ComponentStyleCatalog` 仅解码统一的样式格式并进行 host 内关联，不判断采集来源。原始文档与参数路径保留，用于完整 JSON 查看和参数读取。

`SDKStyleTests.testBothAdaptersProduceTheSameTreeParametersAndStyles` 验证等价的两种输入具有相同节点层级、屏幕边界、源码位置、参数展示和 shape/padding/背景色，并检查原始 JSON 路径。


默认精简规则隐藏 `CompositionLocalProvider` 并保持子节点顺序；关闭精简或关闭组合包装过滤可查看原始层级。它被视为无独立布局的组合包装，不借用后代 shape。仅可点击筛选使用统一的自身 OnClick 语义，并排除 Disabled/未启用的控件；SDK 通过布局归属适配这些字段，两种后端共用筛选逻辑。

精简规则同时隐藏已知的状态/动画值、资源计算、组合包装和副作用调用，包括 `SkippableItem`、`SaveableStateProvider`、`ReusableContent`、`ProvideCommonCompositionLocals`、`animate*AsState` 等，以及已核对源码的 `resourceCardColor`、`masteryColor`、`masteryLabel`。包装上的 `OnClick=false` 不会使其重新显示；跳过节点时始终提升子节点。规则在 macOS 的统一模型层执行，原始采集数据保留。Tooling 不提供返回类型，因此这是一组已知调用规则，不代表能识别所有非 `Unit` 函数，也不会仅凭小写名称或 `Color` 后缀隐藏未知业务组件。

### 悬浮窗选择

未勾选“跳过悬浮窗”时，优先选择目标进程内最后枚举到的可见系统悬浮窗，不要求它持有焦点；勾选后排除系统悬浮窗，接着检查焦点窗口上方的附属面板（包括无焦点 Popup），有面板时采集面板，否则采集焦点窗口。没有焦点时取最后枚举到的可见窗口。截图为整屏截图，不会移除浮层像素；其他应用或进程的浮层需要选择对应采集目标。SDK 端的窗口选择修复需要重新构建并安装接入新版 SDK 的 Android debug 应用。
