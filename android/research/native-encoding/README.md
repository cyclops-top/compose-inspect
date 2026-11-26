# 快速节点树的 C++ 编码实验

实验目录独立于 Gradle 产品模块。测试代码在临时工程中编入独立包 `dev.composeinspect.sample.nativebench`。设备端仍由 Kotlin 在 UI 线程采集 Compose，C++ 只在后台处理已经脱离 Compose 对象的节点数据。

## 真机结果

| 指标 | 产品 Kotlin | Kotlin 直接写固定节点 | Kotlin 打包 + C++ |
|---|---:|---:|---:|
| 常规页面，82,031 字节，后台编码中位数 | 49.89 ms | 34.66 ms | 12.47 ms |
| 性能页面，602,122 字节，后台编码中位数 | 171.82 ms | 99.31 ms | 24.88 ms |
| 性能页面，带截图的请求响应中位数 | 548.18 ms | 538.72 ms | 386.59 ms |
| 性能页面，带截图的请求响应 P95 | 619.81 ms | 826.37 ms | 405.29 ms |
| 同批请求，设备主线程采集中位数 | 147.06 ms | 153.72 ms | 149.02 ms |

固定节点 C++ 方案把带截图的请求中位数缩短了 161.59 ms（29.5%）。性能页面上，Kotlin 准备数据用时中位数 22.31 ms，JNI 调用、C++ 输出与字节数组回传合计 2.55 ms。同样的打包格式交由 Kotlin 输出，总编码中位数为 80.08 ms。该对照使用了不同的整数格式化及字节输出实现，差值同时反映语言、分配策略和实现方式。

这次测量支持保留 Kotlin 读取 Compose，把固定字段编码作为 C++ 候选。请求的主线程采集仍约 150 ms。旧业务 APK 和其他设备未纳入本次比较。

[各模式汇总](results/summary.json) · [常规页面逐轮记录](results/main.json) · [性能页面逐轮记录](results/performance.json) · [带截图的请求记录](results/socket.json)

## 实验设计

GXS‑V1，Android 14（API 34），arm64，Compose 1.12.1，NDK 29.0.14206865。宿主为 debug APK，C++ 使用 `-O2`。两个固定页面分别为常规样例和 24 张卡片、每张嵌套 6 层的性能样例。

微基准每个页面只采一次，输入保留生产采集器构造的 DTO 和窗口结构。每次从同一对象重新编码，重新创建缓冲区和字符串字典。计时包含 UTF-8 准备、整数及字符串表、JNI 数组复制、C++ 输出和返回 Java 的字节数组。校验和采集在计时区间外。每种实现预热 7 次、正式测量 28 次，按轮换及反向顺序平衡先后影响。每次输出都与产品编码器逐字节比对，包含末尾换行。

| 编号 | 实现 | 用途 |
|---|---|---|
| 0 | 现有 Kotlin 编码器 | 产品基线 |
| 1 | Kotlin 遍历并直接写 UTF-8 | 测量换写法的收益 |
| 2 / 3 | Kotlin 生成通用标记序列，由 Kotlin / C++ 输出 | 两端使用同一输入格式 |
| 4 / 5 | Kotlin 将固定节点头部压成整数记录，由 Kotlin / C++ 输出 | 减少重复字段的打包 |
| 6 | Kotlin 直接写固定节点头部 | 无中间数组的 Kotlin 对照 |

整次请求另测。每轮都通过正常 SDK socket 重新采树、取得窗口 PNG、编码、gzip 并经 ADB 接收，复用同一转发端口。生产 SDK 的 APK 签名扫描和过滤照常运行。轮换三种编码器，各预热 3 次、正式 24 次。计时从建立 socket 到收完压缩响应，主机解压、核对树内容和 PNG 在计时之后。该指标不包含桌面导入及绘制。P95 采用最近秩。

## 复现

准备 JDK 21、Android SDK、arm64 设备和 NDK。从本目录运行以下命令；`BENCH_DIR` 指向尚不存在的临时目录，`SERIAL` 为设备序列号。

```sh
python3 prepare.py "$BENCH_DIR" --ndk "$ANDROID_NDK_HOME"
"$BENCH_DIR/gradlew" -p "$BENCH_DIR" :sample:assembleDebug :sample:assembleDebugAndroidTest
adb -s "$SERIAL" install "$BENCH_DIR/sample/build/outputs/apk/debug/sample-debug.apk"
adb -s "$SERIAL" install "$BENCH_DIR/sample/build/outputs/apk/androidTest/debug/sample-debug-androidTest.apk"
pkg=dev.composeinspect.sample.nativebench
for scene in main performance; do
  adb -s "$SERIAL" shell am instrument -w -e scenario "$scene" "$pkg.test/dev.composeinspect.sample.NativeEncodingBenchmark"
  adb -s "$SERIAL" exec-out run-as "$pkg" cat files/native-benchmark.json > "$BENCH_DIR/$scene.json"
done
adb -s "$SERIAL" shell am force-stop "$pkg"
adb -s "$SERIAL" shell am start -W -n "$pkg/dev.composeinspect.sample.MainActivity" --es scenario performance
python3 socket_benchmark.py "$SERIAL" "$BENCH_DIR/socket.json"
adb -s "$SERIAL" uninstall "$pkg.test"
adb -s "$SERIAL" uninstall "$pkg"
```

微基准直接调用采集器，使用默认的空返回类型索引。整次请求使用 SDK 的实际索引，因此两组实验应各自比较。原型只处理受控的快速快照；Kotlin 原型的递归遍历没有生产编码器的环检测和字符上限，C++ 输入来自同一 APK 内的打包器。上线前还需要验证深树、内存上限、异常处理、ABI 和其他设备。
