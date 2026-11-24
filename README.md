# CompScope

macOS 工具开发工作区。

- [macOS 应用工程](macOS/README.md) 支持从 Android 设备抓取静态页面、检查组件并记录本轮问题。
- [Android 采集 SDK 和验证工程](android/README.md) 提供调试包接入说明和真机验证步骤。
- [UI 设计](docs/ui-design/README.md)：macOS 三栏布局与静态线框图。

运行 macOS 应用只需 ADB 和已接入 [采集 SDK](android/README.md) 的调试包，无需安装 Java。

```sh
open macOS/ComposeInspect.xcodeproj
```

或执行 `./macOS/scripts/build-app.sh` 后打开 `macOS/dist/CompScope.app`。在设备上停留到目标页面稳定后，点击相机抓取。

## 通过 Drop 发布 macOS 应用

在项目根目录运行 `drop build macos`，会编译并签名 Release 应用，再生成 `macOS/dist/CompScope-macOS.zip`。

项目已将 `compscope-macos` 绑定到 [compose-inspect 仓库](https://drop.tick-tick.cn/r/compose-inspect) 的 `stable` 渠道。用 `drop targets` 查看绑定。登录有发布权限的账号后，可按应用版本和本次发布编号执行，例如：

```sh
drop publish macos --software-version 0.1.0 --number 1
```

后续发布需使用更大的编号。需要重新绑定时运行 `drop bind compscope-macos drop://drop.tick-tick.cn/compose-inspect compscope-macos stable`。
