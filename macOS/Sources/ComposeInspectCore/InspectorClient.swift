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
    public let environment: [String: String]
    public init(adb: URL, environment: [String: String]) {
        self.adb = adb
        var env = environment
        env["PATH"] = adb.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        if adb.deletingLastPathComponent().lastPathComponent == "platform-tools" {
            let sdk = adb.deletingLastPathComponent().deletingLastPathComponent().path
            env["ANDROID_HOME"] = sdk; env["ANDROID_SDK_ROOT"] = sdk
        }
        self.environment = env
    }
}

public struct CaptureMetadata: Codable, Equatable, Sendable {
    public let serial: String
    public let packageName: String
    public let startedAt: Date
    public let finishedAt: Date
    public let diagnostics: [String]
    public let baselineJSON: Data

    public init(serial: String, packageName: String, startedAt: Date, finishedAt: Date,
                diagnostics: [String], baselineJSON: Data) {
        self.serial = serial
        self.packageName = packageName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.diagnostics = diagnostics
        self.baselineJSON = baselineJSON
    }
}

public struct CapturedSnapshot: Sendable {
    public let snapshot: InspectorSnapshot
    public let imageData: Data
    public var windowImages: [String: WindowImage] = [:]

    public struct WindowImage: Sendable {
        public let png: Data
        public let origin: CGPoint
    }
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

    public static func validPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil
    }
    public static func imageSize(_ data: Data) throws -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CommandFailure.failed("ADB 没有返回可解码的截图。") }
        return CGSize(width: image.width, height: image.height)
    }
}
