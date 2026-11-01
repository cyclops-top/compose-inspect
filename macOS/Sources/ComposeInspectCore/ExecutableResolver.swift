import Foundation

public enum ToolKind: String, CaseIterable, Sendable {
    case adb, java
    public var displayName: String { self == .adb ? "ADB" : "Java" }
}

public struct ExecutableLocation: Equatable, Sendable {
    public let path: String
    public let source: String
    public var url: URL { URL(fileURLWithPath: path) }
    public init(path: String, source: String) { self.path = path; self.source = source }
}

public enum ExecutableResolution: Equatable, Sendable {
    case found(ExecutableLocation)
    case unavailable(String)

    public var location: ExecutableLocation? {
        if case .found(let location) = self { return location }
        return nil
    }
    public var error: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

/// Resolves paths only; never sources a shell, mutates the host environment, or executes a candidate.
public struct ExecutableResolver {
    public let environment: [String: String]
    private let isExecutable: (String) -> Bool

    public init(environment: [String: String], isExecutable: @escaping (String) -> Bool = ExecutableResolver.isExecutableFile) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    public func resolve(_ tool: ToolKind, customPath: String = "") -> ExecutableResolution {
        let custom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            guard let base = normalized(custom) else { return .unavailable("请填写绝对路径，或使用 ~ 表示用户目录。") }
            let paths = tool == .java ? [base, appending("bin/java", to: base), appending("Contents/Home/bin/java", to: base)] : [base]
            if let path = paths.first(where: isExecutable) { return .found(ExecutableLocation(path: path, source: "手动配置")) }
            return .unavailable("手动配置的\(tool.displayName)路径不存在或不是可执行文件。")
        }

        var candidates: [(String, String)] = []
        func add(_ value: String?, suffix: String? = nil, source: String) {
            guard let value, let base = normalized(value) else { return }
            candidates.append((suffix.map { appending($0, to: base) } ?? base, source))
        }
        switch tool {
        case .adb:
            add(environment["ADB"], source: "环境变量 ADB")
            add(environment["ADB_PATH"], source: "环境变量 ADB_PATH")
            add(environment["ANDROID_HOME"], suffix: "platform-tools/adb", source: "环境变量 ANDROID_HOME")
            add(environment["ANDROID_SDK_ROOT"], suffix: "platform-tools/adb", source: "环境变量 ANDROID_SDK_ROOT")
        case .java:
            add(environment["JAVA_HOME"], suffix: "bin/java", source: "环境变量 JAVA_HOME")
            add(environment["JDK_HOME"], suffix: "bin/java", source: "环境变量 JDK_HOME")
        }
        // Empty and relative PATH entries are deliberately excluded: launching a GUI app must not depend on cwd.
        for entry in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            add(String(entry), suffix: tool.rawValue, source: "环境变量 PATH")
        }
        for (path, source) in candidates where isExecutable(path) {
            return .found(ExecutableLocation(path: path, source: source))
        }
        return .unavailable(tool == .adb
            ? "未找到 ADB。请配置 ANDROID_HOME / PATH，或手动选择 adb。"
            : "未找到 Java。请配置 JAVA_HOME / PATH，或手动选择 java。")
    }

    private func normalized(_ path: String) -> String? {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return (expanded as NSString).standardizingPath
    }
    private func appending(_ component: String, to path: String) -> String {
        (path as NSString).appendingPathComponent(component)
    }
}
