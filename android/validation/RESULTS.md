# debugImplementation 能力验证结果

日期：2026-11-24。设备：Android 模拟器 sdk_gphone64_arm64（API 36）。工程：AGP 9.2.1、Gradle 9.4.1、Kotlin/Compose compiler 2.4.21。

示例只通过 `debugImplementation` 接入 SDK。分别对齐 Compose 1.10.6 和 1.12.1 后，两个构建均在主页面、Dialog 和 Popup 采到了业务参数及调用位置。记录见 [results.json](results.json)。

- 调用位置已按业务源码校验文件、行号和 UTF-16 offset。普通参数、默认值和对象字段均通过值断言；点击计数器后再次采集，值从 7 变为 8。
- LazyRow 示例有 100 项，采到了当前已组合的 5 项。Lazy 子组合保留为独立表。InlineWrapper 和 NonRestartableCard 的节点可见，示例参数为空。
- 已检查 release 包的 DEX 和 Manifest，未包含 SDK 初始化器、采集器和 tooling-data。
- 本次记录对应两个分别编译的示例，尚未验证同一预编译 AAR 跨 Compose、Kotlin 编译器及不同宿主运行的兼容性。

当前验证步骤见 [SDK 真机验证](../README.md#sdk-真机验证)。
