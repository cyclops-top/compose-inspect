# 快速采集剩余耗时

在上一轮的 C++ 固定字段编码器（模式 5）上，隔离测试主线程遍历、窗口 PNG 与传输。设备为 GXS‑V1，Android 14、1920×1080、USB ADB。使用 Compose 1.12.1 的 debug 样例和 NDK 29 的 arm64 优化构建。实验代码只进入独立包 `dev.composeinspect.sample.nativebench`。

## 实测结果

**进程启动后的首次抓取。** 5 组独立进程对照，使用优化后的带截图链路，应用已经打开并等待 1 秒。扫描 DEX 与命中索引的请求中位数分别为 3,973 ms 和 1,049 ms。签名阶段从 3,050 ms 降到 45 ms。索引占 12,756 字节。首次建索引耗时 3,080 ms；截断文件和模拟过期键都触发重新扫描，得到相同的树和过滤计数，重建后的下次抓取恢复命中。

**连续抓取。** 下表是各 24 次带截图请求的中位数，括号内为 P95。全部使用同一 C++ JSON 编码器。

| 样例 | 基线 | 仅优化树 | 仅优化 PNG | 树 + PNG |
|---|---:|---:|---:|---:|
| 卡片与文本 | 375（396）ms | 375（392）ms | 192（276）ms | 167（226）ms |
| 卡片叠加纹理 | 757（781）ms | 758（782）ms | 312（375）ms | 292（326）ms |

系统 PNG 编码在两种页面的中位数分别为 303 和 561 ms，原型为 33 和 100 ms。树与图片并行，两种页面在基线下仍需额外等待图片 190 和 454 ms。原型这次只测了不透明 sRGB 窗口。以 1920×1080 为例，扫描缓冲和最坏压缩缓冲各约 5.9 MiB，正式版值得测试逐行压缩和内存峰值。

**大图片的传输。** 单独一轮带纹理的测试，使用快速 PNG 和树优化。在同一 gzip 流内将已编码的 PNG 写成 stored blocks，构帧时间从 87 ms 降至 11 ms，请求中位数从 330 ms 降至 246 ms，传输大小从 1,146,367 增至 1,169,213 字节。独立传输 PNG 为 237 ms。用当前 macOS 的 SDKCompressedResponse 和 ImageIO 成功读取了 stored 帧和 1920×1080 PNG。纯卡片请求的 stored 收益较小，202 ms 降至 193 ms，传输体积增加约 34 KB。

**主线程。** 无截图的独立 2×2 对照中，基线采集 135 ms，仅复用源码上下文缓存 139 ms，仅省去空/单子列表复制 114 ms，两者一起 112 ms。本页面更值得保留的是子列表优化；单独跨抓取复用 ContextCache 没有测到收益。树优化降低了主线程占用，系统 PNG 仍在运行时，节省的时间被等待图片抵消。

[逐轮采样和分阶段统计](results/summary.json)。时间不包含桌面解析和绘制。本次使用独立测试包，尚未测量业务应用的 APK 规模、实际图片分布和多窗口负载。

## 对照条件

两个样例都保留 24 张卡片和 2,949 个 Compose group。第二个样例另外叠加 768×768 的固定渐变与噪声图，测试图片内容对压缩、线载荷和传输的影响。它是合成纹理，不能代替真实业务图片的抽样。

| 模式 | 与 C++ JSON 基线的差异 |
|---|---|
| base | 原有 Compose 遍历、系统 PNG、整个响应 gzip |
| tree | 跨采集复用 Compose tooling 的源码上下文缓存，每 32 次清空；空和单子列表避免复制 |
| png | 使用 C++ 无损 PNG。只接受不透明 sRGB RGBA_8888，按行 Sub 过滤、zlib level 1，其余情况回退系统编码 |
| both | 树优化与 PNG 优化一起开启，沿用原传输格式 |
| split | 在 both 上只 gzip JSON，单独发送 PNG。属于实验协议 |
| treeOnly | 优化后的树且跳过截图，用于估算当前页面图片路径的开销 |

每种模式预热 3 次，正式采集 24 次，按顺序轮换。计时包括创建 socket、重新采集、编码和收完全部字节。ADB 转发复用；桌面 JSON 导入、图片解码和绘制在计时区间外。主线程采集与 PixelCopy 回调、PNG 编码会重叠，不能简单相加。waitPngMs 是主线程采集完成后仍需等待截图的时长。设备端后台的打包、JSON 编码、传输帧构造和写出用请求 ID 对齐 logcat。每个页面对同一 PixelCopy 位图的系统和原型 PNG 各解码一次，逐像素核对。每次请求核对窗口树哈希、组数和 PNG 附件长度。

另一次实验只抓树，将上下文缓存和子列表复用拆成 2×2 组合，各预热 4 次、正式 24 次。同时测量 5 次独立进程启动后的首次和第二次请求。进程冷启动实验没有冲刷操作系统磁盘缓存。

## 复现

先用上级目录的 `prepare.py` 生成隔离工程。将 `probe.patch` 用 `patch -p1` 应用到该工程根目录，再用 NDK 的 `aarch64-linux-android26-clang++` 以 `-O2 -std=c++17 -shared -fPIC -static-libstdc++` 编译 `png.cpp`，链接 `-ljnigraphics -lz`，输出到隔离工程的 `sample/src/debug/jniLibs/arm64-v8a/libpipelinepng.so`。构建并安装该工程的 `:sample:assembleDebug`，从本目录执行以下命令。

```sh
python3 benchmark.py "$SERIAL" results
python3 tree_benchmark.py "$SERIAL" results/tree.json
python3 summarize.py
adb -s "$SERIAL" uninstall dev.composeinspect.sample.nativebench
```

两项测试会轮换独立样例进程。主对照试验完成后才加入细分树开关和 DEX 初始化计时；补丁含两次实验共用的最终版本。

### 追加对照

- `index_benchmark.py` 以同一安装包启动独立进程，在首次请求中交替扫描 DEX 或读取应用私有 code cache 中的返回类型索引。索引记录算法版本、应用更新时间、base/split APK 路径、长度与修改时间，通过 AtomicFile 写入。缺失、键不匹配或读取失败时重新扫描；取同一页面核对完整树哈希和过滤计数。这项测试不在后台提前扫描，因此首次建索引的成本仍计入首个请求。
- `benchmark.py --framing` 复测三种传输实现。both 对 JSON 和 PNG 一起 gzip；stored 在同一个 gzip member 内压缩 JSON，以 DEFLATE stored blocks 写入 PNG 和最后的换行，保留原来的长度头、校验和与解压语义；split 在 JSON 压缩帧后另发 PNG。三组均使用相同的树与 PNG 优化。
- 早期实验直接在 Android Deflater 写入过程中切换级别，在纹理负载中产生过无法解压的帧。最终 stored 原型显式构造 stored blocks，使用 JSON 的 SYNC_FLUSH 边界，并写入整体 CRC32 与 ISIZE。早期数据不纳入最终结果。

执行 `python3 index_benchmark.py "$SERIAL" results/index.json` 和 `python3 benchmark.py --framing "$SERIAL" results/framing` 可重跑两组对照。建议在测试完后再卸载独立包。

### 产品 SDK 的 Startup 验证

`startup_benchmark.py` 使用正常的 `dev.composeinspect.sample` 调试包，比较改动前的 SDK 与实际交付的 AndroidX Startup 实现，未注入 C++ JSON 或 PNG 实验代码。每次启动新的应用进程。control 是旧 SDK 启动 6 秒后抓取；early 是新版在无缓存时启动后立即抓取；prewarm 是新版在无缓存时启动 6 秒后抓取；hit 是保留磁盘索引的新版启动后立即抓取。另测一次损坏索引后重建，核对所有树的哈希和首次请求前的缓存文件。launchMs 来自 ADB Activity 启动统计，不代表逐帧卡顿。
