import AppKit
import ComposeInspectCore
import Darwin
import Observation

struct ToolProbeResult: Sendable {
    let succeeded: Bool
    let message: String
}

@MainActor @Observable
final class ToolchainSettings {
    var adbOverride: String {
        didSet {
            guard adbOverride != oldValue else { return }
            defaults.set(adbOverride, forKey: "toolchain.adbPath"); invalidate(.adb)
        }
    }
    var javaOverride: String {
        didSet {
            guard javaOverride != oldValue else { return }
            defaults.set(javaOverride, forKey: "toolchain.javaPath"); invalidate(.java)
        }
    }
    private(set) var environment: [String: String]
    private(set) var environmentMessage = ""
    private(set) var loadingEnvironment = false
    private var environmentTask: Task<[String: String], Error>?
    private var hasLoadedEnvironment = false
    private let inheritedEnvironment: [String: String]
    private(set) var results: [ToolKind: ToolProbeResult] = [:]
    private(set) var checking: Set<ToolKind> = []
    private var revisions: [ToolKind: UUID] = [:]
    private let defaults: UserDefaults
    var inspectorJarOverride: String {
        didSet { defaults.set(inspectorJarOverride, forKey: "toolchain.inspectorJar") }
    }
    var includeResolutionStack: Bool {
        didSet { defaults.set(includeResolutionStack, forKey: "capture.resolutionStack") }
    }

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
        self.inheritedEnvironment = environment
        adbOverride = defaults.string(forKey: "toolchain.adbPath") ?? ""
        javaOverride = defaults.string(forKey: "toolchain.javaPath") ?? ""
        inspectorJarOverride = defaults.string(forKey: "toolchain.inspectorJar") ?? ""
        includeResolutionStack = defaults.bool(forKey: "capture.resolutionStack")
    }

    func customPath(for tool: ToolKind) -> String { tool == .adb ? adbOverride : javaOverride }

    func resolution(for tool: ToolKind) -> ExecutableResolution {
        ExecutableResolver(environment: environment).resolve(tool, customPath: customPath(for: tool))
    }

    var inspectorJar: URL? {
        let manual = inspectorJarOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return URL(fileURLWithPath: (manual as NSString).expandingTildeInPath) }
        return Bundle.main.url(forResource: "ui-inspector", withExtension: "jar")
    }

    func resolvedTools(requireJava: Bool = true) throws -> InspectorToolchain {
        guard let adb = resolution(for: .adb).location else { throw CommandFailure.configuration(resolution(for: .adb).error ?? "请配置 ADB") }
        let java = resolution(for: .java).location?.url
        if requireJava && java == nil { throw CommandFailure.configuration(resolution(for: .java).error ?? "请配置 Java") }
        let jar = inspectorJar ?? URL(fileURLWithPath: "/missing/ui-inspector.jar")
        if requireJava && !FileManager.default.fileExists(atPath: jar.path) { throw CommandFailure.configuration("未找到 ui-inspector.jar，请在设置的“检查”页选择，或重新构建应用。") }
        return InspectorToolchain(adb: adb.url, java: java ?? URL(fileURLWithPath: "/usr/bin/java"), jar: jar,
                                  environment: environment, resolutionStack: includeResolutionStack)
    }

    func chooseInspectorJar() {
        let panel = NSOpenPanel()
        panel.title = "选择 ui-inspector.jar"; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { inspectorJarOverride = url.path }
    }

    func reset(_ tool: ToolKind) {
        if tool == .adb { adbOverride = "" } else { javaOverride = "" }
    }

    func choose(_ tool: ToolKind) {
        let panel = NSOpenPanel()
        panel.title = tool == .adb ? "选择 adb 可执行文件" : "选择 java 可执行文件或 Java 安装目录"
        panel.message = tool == .adb ? "通常位于 Android SDK 的 platform-tools 目录。" : "可选择 bin/java、JAVA_HOME 目录或 .jdk 安装包。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = tool == .java
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let location = resolution(for: tool).location { panel.directoryURL = location.url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if tool == .adb { adbOverride = url.path } else { javaOverride = url.path }
    }

    func loadEnvironmentIfNeeded() async {
        if !hasLoadedEnvironment { await refreshEnvironment() }
    }

    func refreshEnvironment() async {
        let task: Task<[String: String], Error>
        if let current = environmentTask {
            task = current
        } else {
            let inherited = inheritedEnvironment
            task = Task { try await ShellEnvironment.load(inherited: inherited) }
            environmentTask = task
            loadingEnvironment = true
        }
        defer { environmentTask = nil; loadingEnvironment = false }
        do {
            environment = try await task.value
            environmentMessage = "已读取用户 shell 的 PATH 和工具环境变量。"
        } catch {
            environmentMessage = "未能读取用户 shell 环境，保留当前环境：\(error.localizedDescription)"
        }
        hasLoadedEnvironment = true
        for tool in ToolKind.allCases { invalidate(tool) }
    }

    func validate(_ tool: ToolKind) async {
        guard !checking.contains(tool), let location = resolution(for: tool).location else { return }
        let revision = UUID()
        revisions[tool] = revision
        checking.insert(tool)
        results[tool] = nil
        let inheritedEnvironment = environment
        let result = await Task.detached(priority: .utility) {
            Self.probe(tool, at: location, environment: inheritedEnvironment)
        }.value
        // Path edits invalidate in-flight results; a slow check cannot label a new path as valid.
        guard revisions[tool] == revision else { return }
        results[tool] = result
        checking.remove(tool)
    }

    private func invalidate(_ tool: ToolKind) {
        revisions[tool] = UUID()
        results[tool] = nil
        checking.remove(tool)
    }

    nonisolated private static func probe(_ tool: ToolKind, at location: ExecutableLocation,
                                         environment: [String: String]) -> ToolProbeResult {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeInspect-toolcheck-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = location.url
            process.arguments = tool == .adb ? ["version"] : ["-version"]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            // Version output is small. A file avoids deadlocks when Java writes its version to stderr.
            process.standardOutput = handle
            process.standardError = handle
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                return ToolProbeResult(succeeded: false, message: "检测超时（15 秒）。请确认选择的是正确的可执行文件。")
            }
            process.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let bytes = try reader.read(upToCount: 16_384) ?? Data()
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                return ToolProbeResult(succeeded: false, message: text.isEmpty ? "检测失败，退出码 \(process.terminationStatus)。" : text)
            }
            guard !text.isEmpty else { return ToolProbeResult(succeeded: false, message: "没有返回版本信息，请确认工具路径。") }
            return ToolProbeResult(succeeded: true, message: text)
        } catch { return ToolProbeResult(succeeded: false, message: error.localizedDescription) }
    }
}
