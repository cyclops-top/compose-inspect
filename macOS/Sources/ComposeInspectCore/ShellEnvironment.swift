import Foundation

/// Import only tool discovery variables from the user's login/interactive shell.
public enum ShellEnvironment {
    private static let keys: Set<String> = [
        "PATH", "ADB", "ADB_PATH", "ANDROID_HOME", "ANDROID_SDK_ROOT"
    ]

    public static func load(inherited: [String: String], timeout: TimeInterval = 8) async throws -> [String: String] {
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/"), ExecutableResolver.isExecutableFile(shell) else {
            throw CommandFailure.configuration("用户 shell 不存在或不可执行。")
        }
        // A leading NUL separates any shell startup banner from the environment records.
        let output = try await CommandRunner.run(URL(fileURLWithPath: shell),
            arguments: ["-ilc", "printf '\\000'; exec /usr/bin/env -0"],
            environment: inherited, timeout: timeout)
        guard output.exitCode == 0 else {
            throw CommandFailure.configuration("读取用户 shell 环境失败（退出码 \(output.exitCode)）。")
        }
        return try merging(output.stdout, into: inherited)
    }

    static func merging(_ data: Data, into inherited: [String: String]) throws -> [String: String] {
        var result = inherited
        var foundPath = false
        for record in data.split(separator: 0, omittingEmptySubsequences: false).dropFirst() {
            let entry = String(decoding: record, as: UTF8.self)
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            guard keys.contains(key) else { continue }
            let value = String(entry[entry.index(after: separator)...])
            result[key] = value
            if key == "PATH", !value.isEmpty { foundPath = true }
        }
        guard foundPath else { throw CommandFailure.configuration("用户 shell 没有返回有效的 PATH。") }
        return result
    }
}
