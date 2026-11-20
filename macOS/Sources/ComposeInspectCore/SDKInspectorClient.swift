import Foundation

public struct SDKInspectorClient: Sendable {
    private let adb: InspectorClient
    public init(tools: InspectorToolchain) { adb = InspectorClient(tools: tools) }

    public func capture(serial: String, package: String, deviceName: String, verifyConsistency: Bool = false, skipOverlayWindows: Bool = false,
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
                                       verifyConsistency: verifyConsistency, skipOverlayWindows: skipOverlayWindows, progress: progress)
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
        guard document.root["protocolVersion"]?.int64 == 1 else { throw CommandFailure.failed("SDK 协议版本不兼容。") }
        guard document.root["packageName"]?.string == package else { throw CommandFailure.failed("SDK 响应包名与目标不一致。") }
        guard let pid = document.root["pid"]?.int64, pid > 0 else { throw CommandFailure.failed("SDK 响应缺少有效进程标识。") }
        if let expectedPID, pid != expectedPID { throw CommandFailure.failed("采集期间应用进程已变化。") }
        return document
    }

    private func capture(port: UInt16, serial: String, package: String, deviceName: String, verifyConsistency: Bool, skipOverlayWindows: Bool,
                         progress: @escaping @Sendable (String) async -> Void) async throws -> CapturedSnapshot {
        let started = Date()
        let helloData = try await SDKTransport.request(port: port, command: "hello", timeout: 2, maxBytes: 65536)
        let hello = try Self.validateResponse(helloData, package: package)
        guard hello.root["capabilities"]?.array?.contains(.string("composition-tables")) == true else {
            throw CommandFailure.failed("SDK 未声明组件树采集能力。")
        }
        if skipOverlayWindows && hello.root["capabilities"]?.array?.contains(.string("skip-overlays-v1")) != true {
            throw CommandFailure.failed("SDK 不支持跳过悬浮窗，请更新 SDK。")
        }
        let pid = hello.root["pid"]!.int64!
        let compressed = hello.root["capabilities"]?.array?.contains(.string("gzip-json-v1")) == true
        func readTree() async throws -> Data {
            try await SDKTransport.request(port: port, command: compressed ? "capture-gzip" : "capture",
                                           timeout: 20, compressed: compressed, skipOverlayWindows: skipOverlayWindows)
        }
        await progress("通过 SDK 读取组件树…")
        let readStarted = Date()
        let firstData = try await readTree()
        let readFinished = Date()
        await progress("获取截图并解析 SDK 响应…")
        // The UI tree is already captured. Screenshot I/O and JSON parsing can overlap safely.
        async let screen1Result = adb.adb(["-s", serial, "shell", "-T", "screencap", "-p"])
        let firstDocument = try Self.validateResponse(firstData, package: package, expectedPID: pid)
        let screen1 = try await screen1Result
        let size1 = try InspectorClient.imageSize(screen1.stdout)
        await progress("解析 SDK 节点与参数…")
        let importStarted = Date()
        let first = try SDKSnapshotImporter.decode(firstDocument, imageSize: size1, packageName: package)
        let importFinished = Date()
        var logs = ["采集后端：SDK \(hello.root["sdkVersion"]?.string ?? "未知版本")。",
                    compressed ? "传输：gzip-json-v1 压缩响应。" : "传输：兼容 JSON 响应。",
                    String(format: "耗时：读取 %.2f 秒；截图与解析 %.2f 秒；建树 %.2f 秒。",
                           readFinished.timeIntervalSince(readStarted), importStarted.timeIntervalSince(readFinished),
                           importFinished.timeIntervalSince(importStarted)),
                    "SDK 原始 Composition 表保留为窗口内的独立分支；尚未拼接 Lazy 子表或采集 Android View 属性。",
                    String(decoding: screen1.stderr, as: UTF8.self)]
        logs.append(contentsOf: firstDocument.root["warnings"]?.array?.compactMap(\.string) ?? [])
        if hello.root["capabilities"]?.array?.contains(.string("layout-interactions-v1")) != true {
            logs.append("当前 SDK 未声明交互语义采集能力；仅可点击筛选可能为空，请更新 SDK 后重新编译安装应用。")
        }
        if let collect = firstDocument.root["timings"]?["collectMs"]?.double {
            logs.append(String(format: "耗时：Android 主线程采集 %.0f 毫秒。", collect))
        }
        if let timings = firstDocument.root["timings"], let styles = timings["stylesMs"]?.double,
           let tree = timings["treeMs"]?.double, let parameters = timings["parameterExtractionMs"]?.double {
            logs.append(String(format: "Android 分阶段：样式 %.0f 毫秒；组件树 %.0f 毫秒（其中参数提取 %.0f 毫秒）。",
                               styles, tree, parameters))
        }
        let candidate: InspectorSnapshot
        let image: Data
        let stableLayout: Bool
        let stableImage: Bool
        if verifyConsistency {
            await progress("读取第二轮 SDK 数据并校验界面…")
            let secondData = try await readTree()
            async let screen2Result = adb.adb(["-s", serial, "shell", "-T", "screencap", "-p"])
            let secondDocument = try Self.validateResponse(secondData, package: package, expectedPID: pid)
            let screen2 = try await screen2Result
            let size2 = try InspectorClient.imageSize(screen2.stdout)
            guard size1 == size2 else { throw CommandFailure.failed("采集期间屏幕方向或分辨率变化。") }
            await progress("解析第二轮 SDK 节点与参数…")
            candidate = try SDKSnapshotImporter.decode(secondDocument, imageSize: size2, packageName: package)
            logs.append(String(decoding: screen2.stderr, as: UTF8.self))
            image = screen2.stdout
            stableLayout = InspectorClient.hasSameGeometry(first, candidate)
            stableImage = screen1.stdout == image && !logs.contains { $0.contains("Multiple displays") }
        } else {
            candidate = first; image = screen1.stdout; stableLayout = false; stableImage = false
            logs.append("未启用采集一致性校验，仅采集一轮节点树和截图。")
        }
        let metadata = CaptureMetadata(serial: serial, packageName: package, startedAt: started, finishedAt: Date(),
                                       includeFacets: "sdk:composition-tables,parameters,call-source-locations",
                                       stableLayout: stableLayout, stableImage: stableImage, diagnostics: logs,
                                       baselineJSON: firstData, backend: .sdk)
        try Task.checkCancellation()
        return CapturedSnapshot(snapshot: candidate.withCaptureContext(deviceName: deviceName, metadata: metadata),
                                imageData: image, aligned: stableLayout && stableImage && (candidate.document?.displays.count ?? 0) <= 1)
    }
}
