import Foundation
import CoreGraphics
import ImageIO
import Darwin

public struct CommandOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
}

public enum CommandFailure: LocalizedError {
    case timedOut, failed(String), configuration(String)
    public var errorDescription: String? {
        switch self {
        case .timedOut: "命令执行超时，已停止本次操作。"
        case .failed(let value), .configuration(let value): value
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Binary-safe, shell-free execution. Files avoid stdout/stderr pipe deadlocks and arbitrary truncation.
public enum CommandRunner {
    public static func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 30) async throws -> CommandOutput {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try execute(executable, arguments: arguments, environment: environment, timeout: timeout, cancellation: flag)
            }.value
        } onCancel: { flag.cancel() }
    }
    private static func execute(_ executable: URL, arguments: [String], environment: [String: String],
                                timeout: TimeInterval, cancellation: CancellationFlag) throws -> CommandOutput {
        if cancellation.cancelled { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeInspect-command-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout"), errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation.cancelled || Date() >= deadline {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.cancelled { throw CancellationError() }
                throw CommandFailure.timedOut
            }
        }
        process.waitUntilExit()
        if cancellation.cancelled { throw CancellationError() }
        return CommandOutput(stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL), exitCode: process.terminationStatus)
    }
}

public struct ADBDevice: Identifiable, Sendable, Equatable {
    public let serial: String
    public let state: String
    public let model: String
    public var id: String { serial }
    public var online: Bool { state == "device" }
    public static func parse(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"),
                  ["device", "offline", "unauthorized", "recovery", "sideload", "bootloader", "no"].contains(fields[1]) else { return nil }
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? fields[0]
            return ADBDevice(serial: fields[0], state: fields[1], model: model)
        }
    }
}

public struct InspectorToolchain: Sendable {
    public let adb: URL
    public let java: URL
    public let jar: URL
    public let environment: [String: String]
    public let resolutionStack: Bool
    public init(adb: URL, java: URL, jar: URL, environment: [String: String], resolutionStack: Bool = false) {
        self.adb = adb; self.java = java; self.jar = jar; self.resolutionStack = resolutionStack
        var env = environment
        env["PATH"] = adb.deletingLastPathComponent().path + ":" + java.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        env["JAVA_HOME"] = java.deletingLastPathComponent().deletingLastPathComponent().path
        if adb.deletingLastPathComponent().lastPathComponent == "platform-tools" {
            let sdk = adb.deletingLastPathComponent().deletingLastPathComponent().path
            env["ANDROID_HOME"] = sdk; env["ANDROID_SDK_ROOT"] = sdk
        }
        self.environment = env
    }
}

public enum CaptureBackend: String, Codable, Sendable {
    case sdk, uiInspector
}

public struct CaptureMetadata: Codable, Equatable, Sendable {
    public let serial: String
    public let packageName: String
    public let startedAt: Date
    public let finishedAt: Date
    public let includeFacets: String
    // Older archives may contain measurements from a second capture.
    public let stableLayout: Bool?
    public let stableImage: Bool?
    public let diagnostics: [String]
    public let baselineJSON: Data
    /// Optional for archives created before automatic SDK capture was introduced.
    public let backend: CaptureBackend?

    public init(serial: String, packageName: String, startedAt: Date, finishedAt: Date,
                includeFacets: String, stableLayout: Bool? = nil, stableImage: Bool? = nil,
                diagnostics: [String], baselineJSON: Data, backend: CaptureBackend? = nil) {
        self.serial = serial; self.packageName = packageName
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.includeFacets = includeFacets
        self.stableLayout = stableLayout; self.stableImage = stableImage
        self.diagnostics = diagnostics; self.baselineJSON = baselineJSON; self.backend = backend
    }
}

public struct ParameterRead: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let nodeID: String
    public let parameterID: String
    public let continuationToken: String
    public let readAt: Date
    public let document: InspectorDocument
    public init(nodeID: String, parameterID: String, token: String, document: InspectorDocument) {
        id = UUID(); self.nodeID = nodeID; self.parameterID = parameterID; continuationToken = token
        readAt = Date(); self.document = document
    }
}

public struct CapturedSnapshot: Sendable {
    public let snapshot: InspectorSnapshot
    public let imageData: Data
}

public struct InspectorClient: Sendable {
    public let tools: InspectorToolchain
    public init(tools: InspectorToolchain) { self.tools = tools }

    public func adb(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandOutput {
        let result = try await CommandRunner.run(tools.adb, arguments: arguments, environment: tools.environment, timeout: timeout)
        guard result.exitCode == 0 else { throw CommandFailure.failed(String(decoding: result.stderr + result.stdout, as: UTF8.self)) }
        return result
    }
    public func devices() async throws -> [ADBDevice] {
        ADBDevice.parse(String(decoding: try await adb(["devices", "-l"]).stdout, as: UTF8.self))
    }
    public func packages(serial: String) async throws -> [String] {
        let output = try await adb(["-s", serial, "shell", "pm", "list", "packages"])
        return String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) }.sorted()
    }
    public func foregroundPackage(serial: String) async throws -> String? {
        let result = try await adb(["-s", serial, "shell", "dumpsys", "activity", "activities"])
        let text = String(decoding: result.stdout, as: UTF8.self)
        let pattern = #"(?:topResumedActivity|mResumedActivity)[^\n]*?\s([A-Za-z_][A-Za-z0-9_.]*)/"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    public func capture(serial: String, package: String, deviceName: String, skipOverlayWindows: Bool = false,
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> CapturedSnapshot {
        guard Self.validPackage(package) else { throw CommandFailure.configuration("请输入合法的 Android 包名。") }
        guard FileManager.default.fileExists(atPath: tools.jar.path) else { throw CommandFailure.configuration("ui-inspector.jar 不存在，请重新构建应用或在设置中选择 JAR。") }
        let started = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeInspect-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Also starts/connects the ADB server using the exact executable selected in Settings.
        guard try await devices().contains(where: { $0.serial == serial && $0.online }) else { throw CommandFailure.configuration("设备未授权、离线或已断开。") }
        await progress("连接 inspector，读取组件树…")
        let tree = try await dump(serial: serial, package: package, skipOverlayWindows: skipOverlayWindows, output: directory.appendingPathComponent("tree.json"))
        await progress("获取截图…")
        // shell v2 with no PTY keeps PNG bytes and remote stderr on separate streams.
        // exec-out merges remote warnings into stdout on some Android versions.
        let screen = try await adb(["-s", serial, "shell", "-T", "screencap", "-p"])
        let size = try Self.imageSize(screen.stdout)
        let snapshot = try SnapshotImporter.decode(tree.data, imageSize: size, packageName: package)
        let metadata = CaptureMetadata(serial: serial, packageName: package, startedAt: started, finishedAt: Date(),
                                       includeFacets: facets, diagnostics: [tree.log, String(decoding: screen.stderr, as: UTF8.self)],
                                       baselineJSON: tree.data)
        try Task.checkCancellation()
        return CapturedSnapshot(snapshot: snapshot.withCaptureContext(deviceName: deviceName, metadata: metadata),
                                imageData: screen.stdout)
    }

    /// Compare in tree order without flattening trees or allocating formatted geometry strings.
    static func hasSameGeometry(_ lhs: InspectorSnapshot, _ rhs: InspectorSnapshot) -> Bool {
        var left = Array(lhs.roots.reversed()), right = Array(rhs.roots.reversed())
        while let a = left.popLast() {
            guard let b = right.popLast(), a.id == b.id, a.kind == b.kind,
                  a.name == b.name, a.bounds == b.bounds, (a.label ?? "") == (b.label ?? "") else { return false }
            left.append(contentsOf: a.children.reversed())
            right.append(contentsOf: b.children.reversed())
        }
        return right.isEmpty
    }

    public func parameter(serial: String, package: String, token: String) async throws -> InspectorDocument {
        guard Self.validPackage(package) else { throw CommandFailure.configuration("无效包名") }
        let result = try await invoke(["get-parameter", "--device", serial, "--package", package, "--continuation-token", token])
        return try InspectorDocument(data: result.stdout)
    }
    private var facets: String { "attributes,semantics,system-composables" + (tools.resolutionStack ? ",resolution-stack" : "") }
    private func dump(serial: String, package: String, skipOverlayWindows: Bool, output: URL) async throws -> (data: Data, log: String) {
        let result = try await invoke(["dump-ui", "--device", serial, "--package", package, "--include", facets, "--output", output.path], skipOverlayWindows: skipOverlayWindows)
        return (try Data(contentsOf: output), String(decoding: result.stderr, as: UTF8.self))
    }
    private func invoke(_ arguments: [String], skipOverlayWindows: Bool = false) async throws -> CommandOutput {
        let result = try await CommandRunner.run(tools.java, arguments: (skipOverlayWindows ? ["-Dcomposeinspect.skipOverlays=true"] : []) + ["-jar", tools.jar.path] + arguments,
                                                 environment: tools.environment, timeout: 180)
        guard result.exitCode == 0 else {
            let diagnostic = String(decoding: result.stderr, as: UTF8.self)
            if diagnostic.contains("UnsupportedClassVersionError") {
                throw CommandFailure.configuration("Java 版本不兼容：当前 ui-inspector.jar 含 Java 25 编译的类。请在 ⌘, 设置中选择 Java 25 或更新版本。\n\n" + diagnostic)
            }
            throw CommandFailure.failed(diagnostic)
        }
        return result
    }
    public static func validPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil
    }
    public static func imageSize(_ data: Data) throws -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CommandFailure.failed("ADB 没有返回可解码的截图。") }
        return CGSize(width: image.width, height: image.height)
    }
}
