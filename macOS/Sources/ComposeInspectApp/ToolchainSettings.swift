import AppKit
import ComposeInspectCore
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
            defaults.set(adbOverride, forKey: "toolchain.adbPath"); invalidateADB()
        }
    }
    private(set) var environment: [String: String]
    private(set) var environmentMessage = ""
    private(set) var loadingEnvironment = false
    private var environmentTask: Task<[String: String], Error>?
    private var hasLoadedEnvironment = false
    private var hasCheckedStartup = false
    var showEnvironmentSetup = false
    private let inheritedEnvironment: [String: String]
    private(set) var adbResult: ToolProbeResult?
    private(set) var checkingADB = false
    private var probeRevision = UUID()
    private let defaults: UserDefaults
    private(set) var recentProjects: [String] {
        didSet { defaults.set(recentProjects, forKey: "source.recentProjects") }
    }
    var managingProjects = false
    private(set) var androidProjectPath: String {
        didSet { defaults.set(androidProjectPath, forKey: "source.androidProjectPath") }
    }
    var skipOverlayWindows: Bool {
        didSet { defaults.set(skipOverlayWindows, forKey: "capture.skipOverlays") }
    }
    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
        self.inheritedEnvironment = environment
        let current = defaults.string(forKey: "source.androidProjectPath") ?? ""
        recentProjects = defaults.stringArray(forKey: "source.recentProjects") ?? (current.isEmpty ? [] : [current])
        androidProjectPath = current
        adbOverride = defaults.string(forKey: "toolchain.adbPath") ?? ""
        skipOverlayWindows = defaults.bool(forKey: "capture.skipOverlays")
    }

    var adbResolution: ExecutableResolution {
        ExecutableResolver(environment: environment).resolveADB(customPath: adbOverride)
    }

    func resolvedTools() throws -> InspectorToolchain {
        let resolution = adbResolution
        guard let adb = resolution.location else { throw CommandFailure.configuration(resolution.error ?? "请配置 ADB") }
        return InspectorToolchain(adb: adb.url, environment: environment)
    }

    func chooseAndroidProject() {
        let panel = NSOpenPanel()
        panel.title = "选择 Android 工程目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if !androidProjectPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: androidProjectPath) }
        if panel.runModal() == .OK, let url = panel.url { openProject(url.path) }
    }

    func openProject(_ path: String) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            let alert = NSAlert()
            alert.messageText = "工程目录不存在"
            alert.informativeText = path
            alert.runModal()
            return
        }
        androidProjectPath = path
        recentProjects = Array(([path] + recentProjects.filter { $0 != path }).prefix(10))
    }

    func closeProject() { androidProjectPath = "" }

    func forgetProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
    }

    func clearRecentProjects() {
        recentProjects = []
    }

    func chooseADB() {
        let panel = NSOpenPanel()
        panel.title = "选择 adb 可执行文件"
        panel.message = "通常位于 Android SDK 的 platform-tools 目录。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let location = adbResolution.location { panel.directoryURL = location.url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adbOverride = url.path
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
        invalidateADB()
    }

    func validateADB() async {
        guard !checkingADB else { return }
        let resolution = adbResolution
        guard let location = resolution.location else {
            adbResult = ToolProbeResult(succeeded: false, message: resolution.error ?? "未找到 ADB")
            return
        }
        let revision = probeRevision
        checkingADB = true
        let result: ToolProbeResult
        do {
            let output = try await CommandRunner.run(location.url, arguments: ["version"], environment: environment, timeout: 15)
            let version = String(decoding: (output.stdout + output.stderr).prefix(16_384), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = ToolProbeResult(succeeded: output.exitCode == 0 && !version.isEmpty,
                                     message: version.isEmpty ? "ADB 未返回版本信息，请检查路径。" : version)
        } catch {
            result = ToolProbeResult(succeeded: false, message: error.localizedDescription)
        }
        guard revision == probeRevision else { return }
        adbResult = result
        checkingADB = false
    }

    func checkStartupEnvironment() async {
        guard !hasCheckedStartup else { return }
        hasCheckedStartup = true
        await validateADB()
        showEnvironmentSetup = adbResult?.succeeded == false
    }

    private func invalidateADB() {
        probeRevision = UUID()
        adbResult = nil
        checkingADB = false
    }
}
