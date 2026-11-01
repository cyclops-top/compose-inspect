# UI Inspector

ComposeInspect 下的 UI Inspector 子项目，源码、依赖、构建和运行产物均收纳在本目录内。以下命令在 `ui-inspector/` 目录执行；从工作区根目录执行时需添加 `ui-inspector/` 前缀。当前模块用于 Android UI 检查。

## 编译与运行

当前工具链适用于 Apple Silicon macOS。原生编译需要系统安装 Xcode Command Line Tools（`xcode-select -p` 可检查）；JDK、Bazel、Android SDK/NDK 和 Java/Kotlin 依赖均位于项目内。

```sh
./build.sh
./bin/ui-inspector --help
./bin/ui-inspector dump-ui --help
```

`build.sh` 从源码构建 deploy JAR，成功后更新 `lib/ui-inspector.jar`。默认使用 4 个并行任务，可通过 `BUILD_JOBS` 调整。附加参数会传给 Bazel，例如 `./build.sh --verbose_failures`。

运行入口使用项目内 JBR 25 和 ADB，不依赖原 `~/.local/share/ui-inspector` 安装，也不依赖全局 `JAVA_HOME` 或 Android SDK 配置。JAR 缺失时会自动执行构建。源码改动后应重新运行 `./build.sh`。

## 目录

- `vendor/android/`：完整迁入的原 Bazel 源码工作区及预编译依赖。
- `vendor/ui-inspector/`：指向 `android/tools/base/ui-inspector` 的相对符号链接，作为模块编辑入口，避免维护两份源码。
- `vendor/android/prebuilts/studio/jdk/`：JDK/JBR。
- `vendor/android/prebuilts/studio/sdk/darwin/`：Android build-tools、platforms、platform-tools、NDK、CMake 和 licenses；未迁入模拟器及系统镜像。
- `vendor/bazel-repository-cache/`：迁入的 Bazel 仓库下载缓存；与可清理的构建产物分开保存。
- `.build/`：项目独立的 Bazel 服务、外部仓库展开目录、编译缓存和日志，可删除后重建。
- `lib/ui-inspector.jar`：可运行产物。

搬动整个项目时应保留 `vendor/` 内部的相对符号链接和可执行文件权限；`.build/` 无需随项目搬动。Bazel 首次构建可能访问远程仓库补充未缓存的依赖。

## 迁移验证

已在项目独立的 Bazel 输出目录完成首次源码构建（1178 个 actions），随后 `./build.sh --nofetch` 验证通过。新 JAR 的 `--version`、`dump-ui --help` 和项目内 `adb version` 均正常。也已在 `/tmp` 下、使用最小 PATH 和无效全局 Java/SDK 配置验证命令运行。

移入 `ui-inspector/` 后已重新完整构建并验证命令运行，日志见 `.build/relocation-build.log`。迁入前日志位于 `.build/first-build.log` 和 `.build/verify-build.log`。尚未执行连接 Android 真机的 UI 抓取验证。

## 来源

- 原源码：`/Users/justin/.local/share/ui-inspector/source`。
- 原命令：`/Users/justin/.local/bin/ui-inspector`。
- 现有运行输出：`/Users/justin/Documents/UI-Inspector-Output`，未迁移。

原安装保持可用。`vendor/build-original.sh` 仅保留为原始构建记录，不是当前构建入口。

## 版本控制范围

主仓库保存 `vendor/android/tools/base/ui-inspector/` 的源码快照，包含 ComposeInspect 的分层样式采集扩展；原上游仓库保留在本地。上游来源为 `https://android.googlesource.com/platform/tools/base`，快照基于提交 `45628254f0f8a9bb3755d73f3d30ca78fbb2153d`。其余 Android 构建工作区、SDK/JDK、Bazel 缓存及生成的 JAR 不纳入主仓库，需要在本地另行准备。
