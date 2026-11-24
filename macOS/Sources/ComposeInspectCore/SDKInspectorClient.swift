import Foundation

public struct SDKInspectorClient: Sendable {
    public static let supportedSDKVersion = "0.1.3"
    private let adb: InspectorClient
    public init(tools: InspectorToolchain) { adb = InspectorClient(tools: tools) }

    public func capture(serial: String, package: String, deviceName: String, skipOverlayWindows: Bool = false,
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> CapturedSnapshot {
        guard InspectorClient.validPackage(package) else { throw CommandFailure.configuration("无效包名") }
        try Task.checkCancellation()
        await progress("检测应用 SDK…")
        // Finish this short allocation even on cancellation, so its port is known and can be removed.
        let forward = Task.detached {
            try await adb.adb(["-s", serial, "forward", "tcp:0", "localabstract:composeinspect.\(package)"], timeout: 5)
        }
        let output = try await forward.value
        guard let port = UInt16(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            throw CommandFailure.failed("ADB 未返回有效的 SDK 转发端口。")
        }
        let result: CapturedSnapshot
        do {
            try Task.checkCancellation()
            result = try await capture(port: port, serial: serial, package: package, deviceName: deviceName,
                                       skipOverlayWindows: skipOverlayWindows, progress: progress)
        } catch {
            await removeForward(port: port, serial: serial)
            throw error
        }
        await removeForward(port: port, serial: serial)
        try Task.checkCancellation()
        return result
    }

    private func removeForward(port: UInt16, serial: String) async {
        // Cleanup must survive the capture task's cancellation, and never removes other forwards.
        await Task.detached { _ = try? await adb.adb(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5) }.value
    }

    static func validateResponse(_ data: Data, package: String, expectedPID: Int64? = nil) throws -> InspectorDocument {
        let document = try InspectorDocument(data: data)
        if let error = document.root["error"]?.string { throw CommandFailure.failed("SDK：\(error)") }
        let reported = document.root["sdkVersion"]?.string
        guard reported == supportedSDKVersion, document.root["protocolVersion"]?.int64 == 1 else {
            throw CommandFailure.failed("当前 CompScope 仅支持采集 SDK \(supportedSDKVersion)（协议 1）。目标应用报告 SDK \(reported ?? "未知")，协议 \(document.root["protocolVersion"]?.display ?? "未知")。请使用对应 SDK 重新构建调试包。")
        }
        guard document.root["packageName"]?.string == package else { throw CommandFailure.failed("SDK 响应包名与目标不一致。") }
        guard let pid = document.root["pid"]?.int64, pid > 0 else { throw CommandFailure.failed("SDK 响应缺少有效进程标识。") }
        if let expectedPID, pid != expectedPID { throw CommandFailure.failed("采集期间应用进程已变化。") }
        return document
    }

    private func capture(port: UInt16, serial: String, package: String, deviceName: String, skipOverlayWindows: Bool,
                         progress: @escaping @Sendable (String) async -> Void) async throws -> CapturedSnapshot {
        let started = Date()
        let helloData: Data
        do {
            helloData = try await SDKTransport.request(port: port, command: "hello", timeout: 2, maxBytes: 65536)
        } catch let handshakeError {
            try Task.checkCancellation()
            do {
                _ = try await adb.adb(["-s", serial, "shell", "run-as", package, "true"], timeout: 2)
            } catch CommandFailure.failed(let message) where message.split(whereSeparator: \.isNewline)
                .contains("run-as: package not debuggable: \(package)") {
                throw CommandFailure.failed("设备上的 \(package) 是不可调试版本。请安装并打开通过 debugImplementation 接入采集 SDK 的调试包，再重新抓取。")
            } catch {
                // An unavailable run-as command cannot establish whether the package is debuggable.
            }
            try Task.checkCancellation()
            throw CommandFailure.failed("无法连接 \(package) 的采集 SDK。请确认已通过 debugImplementation 接入 SDK，并已安装、打开该调试版本。\n\(handshakeError.localizedDescription)")
        }
        let hello = try Self.validateResponse(helloData, package: package)
        guard hello.root["capabilities"]?.array?.contains(.string("composition-tables")) == true else {
            throw CommandFailure.failed("SDK 未声明组件树采集能力。")
        }
        if skipOverlayWindows && hello.root["capabilities"]?.array?.contains(.string("skip-overlays-v1")) != true {
            throw CommandFailure.failed("SDK 不支持跳过悬浮窗，请更新 SDK。")
        }
        let pid = hello.root["pid"]!.int64!
        guard hello.root["capabilities"]?.array?.contains(.string("gzip-json-v1")) == true else {
            throw CommandFailure.failed("SDK 缺少压缩采集能力，请使用开发版本 \(Self.supportedSDKVersion)。")
        }
        await progress("通过 SDK 读取组件树…")
        let readStarted = Date()
        let data = try await SDKTransport.request(port: port, command: "capture-gzip",
                                                  timeout: 20, compressed: true, skipOverlayWindows: skipOverlayWindows)
        let readFinished = Date()
        await progress("获取截图并解析 SDK 响应…")
        // The UI tree is already captured. Screenshot I/O and JSON parsing can overlap safely.
        async let screenResult = adb.adb(["-s", serial, "shell", "-T", "screencap", "-p"])
        let document = try Self.validateResponse(data, package: package, expectedPID: pid)
        let screen = try await screenResult
        let size = try InspectorClient.imageSize(screen.stdout)
        await progress("解析 SDK 节点与参数…")
        let importStarted = Date()
        let snapshot = try SDKSnapshotImporter.decode(document, imageSize: size, packageName: package)
        let importFinished = Date()
        var logs = ["采集后端：SDK \(hello.root["sdkVersion"]?.string ?? "未知版本")。",
                    "传输：gzip-json-v1 压缩响应。",
                    String(format: "耗时：读取 %.2f 秒；截图与解析 %.2f 秒；建树 %.2f 秒。",
                           readFinished.timeIntervalSince(readStarted), importStarted.timeIntervalSince(readFinished),
                           importFinished.timeIntervalSince(importStarted)),
                    "SDK 原始 Composition 表保留为窗口内的独立分支；尚未拼接 Lazy 子表或采集 Android View 属性。",
                    String(decoding: screen.stderr, as: UTF8.self)]
        logs.append(contentsOf: document.root["warnings"]?.array?.compactMap(\.string) ?? [])
        if hello.root["capabilities"]?.array?.contains(.string("layout-interactions-v1")) != true {
            logs.append("当前 SDK 未声明交互语义采集能力；仅可点击筛选可能为空，请更新 SDK 后重新编译安装应用。")
        }
        if let collect = document.root["timings"]?["collectMs"]?.double {
            logs.append(String(format: "耗时：Android 主线程采集 %.0f 毫秒。", collect))
        }
        if let timings = document.root["timings"], let styles = timings["stylesMs"]?.double,
           let tree = timings["treeMs"]?.double, let parameters = timings["parameterExtractionMs"]?.double {
            logs.append(String(format: "Android 分阶段：样式 %.0f 毫秒；组件树 %.0f 毫秒（其中参数提取 %.0f 毫秒）。",
                               styles, tree, parameters))
        }
        let metadata = CaptureMetadata(serial: serial, packageName: package, startedAt: started, finishedAt: Date(),
                                       diagnostics: logs, baselineJSON: data)
        try Task.checkCancellation()
        return CapturedSnapshot(snapshot: snapshot.withCaptureContext(deviceName: deviceName, metadata: metadata),
                                imageData: screen.stdout)
    }
}
