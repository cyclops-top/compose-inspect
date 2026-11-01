import XCTest
@testable import ComposeInspectCore

final class ShellEnvironmentTests: XCTestCase {
    func testImportsToolVariablesWithoutStartupBannerOrUnrelatedSecrets() throws {
        let data = Data("Welcome PATH=wrong\n\0PATH=/custom tools/bin:/usr/bin\0JAVA_HOME=/jdk=25\0ADB_PATH=/sdk/adb\0TOKEN=secret\0HOME=/other\0".utf8)
        let result = try ShellEnvironment.merging(data, into: ["PATH": "/usr/bin", "HOME": "/original", "EXISTING": "kept"])
        XCTAssertEqual(result["PATH"], "/custom tools/bin:/usr/bin")
        XCTAssertEqual(result["JAVA_HOME"], "/jdk=25")
        XCTAssertEqual(result["ADB_PATH"], "/sdk/adb")
        XCTAssertEqual(result["HOME"], "/original")
        XCTAssertEqual(result["EXISTING"], "kept")
        XCTAssertNil(result["TOKEN"])
        XCTAssertEqual(try ShellEnvironment.merging(Data("\0PATH=/bin\0".utf8), into: [:])["PATH"], "/bin")
        XCTAssertThrowsError(try ShellEnvironment.merging(Data("banner\0JAVA_HOME=/jdk\0".utf8), into: [:]))
    }

    func testGUIEnvironmentLoadsLoginAndInteractiveShellConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeInspect-shell-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("export JAVA_HOME='/example/jdk'\n".utf8).write(to: directory.appendingPathComponent(".zprofile"))
        try Data("export PATH='/example/platform-tools:/usr/bin:/bin'\nprintf 'startup banner\\n'\n".utf8)
            .write(to: directory.appendingPathComponent(".zshrc"))
        let environment = ["SHELL": "/bin/zsh", "HOME": directory.path, "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin"]
        let loaded = try await ShellEnvironment.load(inherited: environment)
        XCTAssertEqual(loaded["PATH"], "/example/platform-tools:/usr/bin:/bin")
        XCTAssertEqual(loaded["JAVA_HOME"], "/example/jdk")
        XCTAssertEqual(loaded["HOME"], directory.path)
    }

    func testBadShellAndStartupTimeoutReturnErrors() async throws {
        do {
            _ = try await ShellEnvironment.load(inherited: ["SHELL": "/missing/shell"])
            XCTFail("Expected invalid shell error")
        } catch { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComposeInspect-shell-timeout-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("while true; do :; done\n".utf8).write(to: directory.appendingPathComponent(".zshrc"))
        do {
            _ = try await ShellEnvironment.load(inherited: ["SHELL": "/bin/zsh", "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin"], timeout: 0.2)
            XCTFail("Expected timeout")
        } catch CommandFailure.timedOut { }
    }
}
