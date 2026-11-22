# CompScope

macOS 工具开发工作区。

- [macOS 应用工程](macOS/README.md) 支持从 Android 设备抓取静态页面、检查组件并记录本轮问题。
- [Android SDK 验证工程](android/README.md)：只加 `debugImplementation` 的 Compose 采集实验、分模块 SDK 与 ui-inspector 对照验证。
- [ui-inspector/](ui-inspector/)：UI Inspector 源码、依赖、构建脚本和运行产物，详见 [构建说明](ui-inspector/README.md)。
- [macOS 技术方案](docs/macos-technical-plan.md)：ui-inspector 接入、截图与组件树关联、精简 AI 定位文本及实施阶段。
- [UI 设计](docs/ui-design/README.md)：macOS 三栏布局与静态线框图。

从项目根目录执行：

```sh
./ui-inspector/build.sh
./ui-inspector/bin/ui-inspector --help
```

运行 macOS 应用：

```sh
open macOS/ComposeInspect.xcodeproj
```

或执行 `./macOS/scripts/build-app.sh` 后打开 `macOS/dist/CompScope.app`。在设备上停留到目标页面稳定后，点击相机抓取。
