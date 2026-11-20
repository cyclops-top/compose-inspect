# UI Inspector

CompScope 下的 UI Inspector 子项目，源码、依赖、构建和运行产物均收纳在本目录内。以下命令在 `ui-inspector/` 目录执行；从工作区根目录执行时需添加 `ui-inspector/` 前缀。当前模块用于 Android UI 检查。

## 编译与运行

当前工具链适用于 Apple Silicon macOS。支持两种构建方式：

- 完整 Android 工作区：沿用 Bazel，重建包括底层 Agent 在内的全部模块。
- 当前源码快照：`build.sh` 在未安装项目内 Bazel 时自动调用 `build-standalone.py`，从源码重编 Kotlin CLI/Core、Java View Inspector 并生成 DEX；复用经过 SHA-256 固定的基线 JAR 中未修改的底层 Agent、协议和第三方运行库。这是增量源码构建，不是完整 AOSP 构建。

```sh
./build.sh
./bin/ui-inspector --help
./bin/ui-inspector dump-ui --help
```

增量构建需要 Java 25+、Python 3、Android SDK platform `android-36` 和 build-tools `36.0.0`。可通过 `JAVA_HOME`、`ANDROID_HOME` 指定；macOS 默认检测本机 JDK 和 `~/Library/Android/sdk`。所需编译依赖从本机 Gradle 缓存或上游下载，按 `standalone-build.lock.json` 中的 SHA-256 验证。

基线 JAR 保存在 `.build/standalone/bootstrap.jar`。清理 `.build` 前请保留它；在新机器上用 `UI_INSPECTOR_BOOTSTRAP=/path/to/original.jar ./build.sh` 指定符合锁文件哈希的原始包。不能拿优化后的 JAR 替代原始基线。脚本检查复用层的源码指纹，若 common/protocol、payload 或 art-tooling 改动，会拒绝增量构建，要求完整 Bazel 构建和重新锁定基线。

成功后原子更新 `lib/ui-inspector.jar`；构建失败保留旧产物。构建来源和源码哈希写入 JAR 的 `META-INF/composeinspect-build.json` 及 `.build/standalone/build-info.json`。完整 Bazel 模式仍支持 `BUILD_JOBS` 和附加 Bazel 参数；增量模式不接收 Bazel 参数。

运行入口优先尊重 `JAVA_HOME`/`ANDROID_HOME`，其次使用项目内工具，缺失时检测本机环境。源码变更后运行 `./build.sh`；JAR 不存在时启动脚本也会触发构建。

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

主仓库保存 `vendor/android/tools/base/ui-inspector/` 的源码快照，包含 CompScope 的分层样式采集扩展；原上游仓库保留在本地。上游来源为 `https://android.googlesource.com/platform/tools/base`，快照基于提交 `45628254f0f8a9bb3755d73f3d30ca78fbb2153d`。其余 Android 构建工作区、SDK/JDK、Bazel 缓存及生成的 JAR 不纳入主仓库，需要在本地另行准备。

## Kotlin metadata 2.4 兼容

Compose 1.12.1 的官方 inspector 内嵌 metadata 解析库最多接受 2.3，读取 Kotlin 2.4 应用参数时会失败。目前对 **Compose 1.12.1** 自动选择内置兼容版：保留原 inspector 与协议，只升级其隔离命名空间中的 `kotlin-metadata-jvm` 至 2.4.21，继续严格校验版本。其他 Compose 版本仍使用官方下载流程；显式 `--compose-inspector` 优先。官方缓存不覆盖，兼容版缓存损坏会重新提取。

可复现构建、固定输入校验值和验证方式见 [compat/README.md](compat/README.md)。源码构建缺少兼容产物时会自动调用其构建脚本。

## 本地性能优化维护

优化基线、逐项补丁说明、验证限制及新版选择性合并流程见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md)。
