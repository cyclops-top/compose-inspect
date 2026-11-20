import XCTest
import ComposeInspectCore
@testable import ComposeInspectApp

final class AndroidSourceFilesTests: XCTestCase {
    @MainActor
    func testSDKIndexWatchesPackageEditsDuplicatesAndDirectoryMoves() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("Screen.kt")
        let content = "/* package fake */\npackage dev.composeinspect.sample\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        let index = ProjectSourceIndex()
        index.open(root.path)
        defer { index.open("") }
        let source = SourceAnchor(file: "Screen.kt", line: 2, packageHash: 577838147)
        func expect(_ paths: [String]) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while index.matches(source) != paths && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(index.matches(source), paths)
        }
        try await expect(["Screen.kt"])
        XCTAssertTrue(index.confirms(source))
        XCTAssertFalse(index.confirms(SourceAnchor(file: "Screen.kt", packageHash: -1)))
        let module = root.appendingPathComponent("feature")
        try fm.createDirectory(at: module, withIntermediateDirectories: true)
        try content.write(to: module.appendingPathComponent("Screen.kt"), atomically: true, encoding: .utf8)
        try await expect(["Screen.kt", "feature/Screen.kt"])
        XCTAssertFalse(index.confirms(source))
        try "package different".write(to: file, atomically: true, encoding: .utf8)
        try await expect(["feature/Screen.kt"])
        let moved = root.appendingPathComponent("renamed")
        try fm.moveItem(at: module, to: moved)
        try await expect(["renamed/Screen.kt"])
        try fm.removeItem(at: moved)
        try await expect([])
    }

    @MainActor
    func testFreshSearchIncludesNewDuplicatesAndDropsMovedOrDeletedFiles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func write(_ directory: String) throws -> URL {
            let folder = root.appendingPathComponent(directory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Screen.kt")
            try Data().write(to: file)
            return file
        }
        let first = try write("app/src")
        _ = try write("app/build/generated")
        _ = try write(".gradle")
        let unique = try await AndroidSourceFiles.matches(file: "Screen.kt", project: root)
        XCTAssertEqual(unique, ["app/src/Screen.kt"])
        let second = try write("feature login/src")
        let duplicates = try await AndroidSourceFiles.matches(file: "Screen.kt", project: root)
        XCTAssertEqual(duplicates, ["app/src/Screen.kt", "feature login/src/Screen.kt"])
        try fm.moveItem(at: first, to: first.deletingLastPathComponent().appendingPathComponent("Renamed.kt"))
        try fm.removeItem(at: second)
        let missing = try await AndroidSourceFiles.matches(file: "Screen.kt", project: root)
        XCTAssertTrue(missing.isEmpty)
    }

    @MainActor
    func testRecentProjectsMigrateReorderAndPersistIndependentlyOfSelection() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "source.androidProjectPath")
        let settings = ToolchainSettings(defaults: defaults)
        XCTAssertEqual(settings.recentProjects, [root.path])

        for index in 0..<12 {
            let url = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            settings.openProject(url.path)
        }
        let path = root.appendingPathComponent("3").path
        settings.openProject(path)
        XCTAssertEqual(settings.recentProjects.first, path)
        XCTAssertEqual(Set(settings.recentProjects).count, 10)
        XCTAssertEqual(settings.recentProjects.count, 10)
        settings.forgetProject(path)
        XCTAssertFalse(settings.recentProjects.contains(path))
        settings.clearRecentProjects()
        let restored = ToolchainSettings(defaults: defaults)
        XCTAssertEqual(restored.androidProjectPath, path)
        XCTAssertTrue(restored.recentProjects.isEmpty)
        restored.closeProject()
        XCTAssertTrue(ToolchainSettings(defaults: defaults).androidProjectPath.isEmpty)
    }
}
