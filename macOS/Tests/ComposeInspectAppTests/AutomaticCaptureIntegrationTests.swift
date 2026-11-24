import XCTest
import AppKit
@testable import ComposeInspectApp
@testable import ComposeInspectCore

@MainActor
final class AutomaticCaptureIntegrationTests: XCTestCase {
    func testStartupAllowsSDKWithoutJavaOrJar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("adb")
        try Data("#!/bin/sh\nprintf 'Android Debug Bridge version 1.0.41\\n'\n".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let suite = "sdk-startup-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/missing/java", forKey: "toolchain.javaPath")
        defaults.set("/missing/inspector.jar", forKey: "toolchain.inspectorJar")
        let settings = ToolchainSettings(defaults: defaults, environment: ["PATH": directory.path])
        settings.adbOverride = adb.path
        await settings.checkStartupEnvironment()
        XCTAssertFalse(settings.showEnvironmentSetup)
        XCTAssertEqual(settings.adbResult?.succeeded, true)
        XCTAssertEqual(try settings.resolvedTools().adb, adb)
    }

    func testMissingSDKReportsIntegrationStep() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_AUTO_LIVE"] == "1" else { throw XCTSkip("Real device required") }
        let adb = URL(fileURLWithPath: try XCTUnwrap(env["COMPOSEINSPECT_ADB"]))
        let session = DeviceSession()
        let serial = try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"])
        let suite = "missing-sdk-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolchainSettings(defaults: defaults, environment: ["ADB": adb.path, "PATH": "/nonexistent"])
        try await session.refresh(settings: settings)
        try await session.selectDevice(serial, settings: settings)
        session.packageName = "dev.composeinspect.missingfixture"
        do {
            _ = try await session.capture(settings: settings)
            XCTFail("Expected a missing SDK error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("debugImplementation"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("是不可调试版本"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(session.packageName))
        }
    }

    func testConfiguredForegroundCaptureUsesExpectedBackendAndSharedInteractions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_AUTO_LIVE"] == "1" else { throw XCTSkip("Explicit real-device auto capture opt-in required") }
        _ = NSApplication.shared
        let suite = "sdk-live-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolchainSettings(defaults: defaults, environment: ["PATH": "/nonexistent"])
        settings.adbOverride = try XCTUnwrap(env["COMPOSEINSPECT_ADB"])
        let standard = UserDefaults.standard
        let oldCompact = standard.object(forKey: "hideInternalNodes")
        let oldClickable = standard.object(forKey: "onlyClickableNodes")
        defer {
            standard.set(oldCompact, forKey: "hideInternalNodes")
            standard.set(oldClickable, forKey: "onlyClickableNodes")
        }
        let store = WorkspaceStore(filterDefaults: defaults)
        store.onlyClickableNodes = false
        store.hideInternalNodes = false
        try await store.deviceSession.refresh(settings: settings)
        try await store.deviceSession.selectDevice(try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"]), settings: settings)
        store.deviceSession.automaticallySelectForeground = true
        await store.capture(settings: settings)
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        XCTAssertEqual(store.snapshot.packageName, env["COMPOSEINSPECT_PACKAGE"])
        XCTAssertNotNil(store.snapshot.captureMetadata)
        let card = try XCTUnwrap(store.snapshot.nodes.first {
            env["COMPOSEINSPECT_GENERIC_APP"] == "1" ? !$0.parameters.isEmpty : $0.name == "ParameterCard"
        })
        store.select(card.id)
        XCTAssertEqual(store.selectedNodeID, card.id)
        let title = try XCTUnwrap(env["COMPOSEINSPECT_GENERIC_APP"] == "1" ? card.parameters.first : card.parameters.first { $0.name == "title" })
        store.toggleParameter(title.id, enabled: true)
        let key = try XCTUnwrap(store.selectedKey)
        store.edit("验证自动采集", for: key, revision: store.issueEditRevision)
        if env["COMPOSEINSPECT_GENERIC_APP"] != "1" { XCTAssertTrue(store.currentText.contains("explicit-title")) }
        XCTAssertTrue(store.currentText.contains("验证自动采集"))
        store.showRawJSON()
        XCTAssertNotNil(store.rawPresentation)
        XCTAssertFalse(store.snapshot.document?.originalJSON.isEmpty ?? true)
        print("SDK_LIVE nodes=\(store.snapshot.nodes.count) diagnostics=\(store.snapshot.captureMetadata?.diagnostics ?? [])")
        if let output = env["COMPOSEINSPECT_LIVE_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try store.snapshot.document?.originalJSON.write(to: directory.appendingPathComponent("tree.json"))
            try JSONEncoder().encode(store.snapshot.captureMetadata).write(to: directory.appendingPathComponent("metadata.json"))
        }
    }
    func testSingleClickValidationOnSample() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPSCOPE_SAMPLE_CLICK"] == "1" else { throw XCTSkip("Requires foreground sample counter") }
        _ = NSApplication.shared
        let suite = "verify-click-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolchainSettings(defaults: defaults)
        settings.skipOverlayWindows = true
        settings.adbOverride = try XCTUnwrap(env["COMPOSEINSPECT_ADB"])
        let store = WorkspaceStore(filterDefaults: defaults)
        try await store.deviceSession.refresh(settings: settings)
        try await store.deviceSession.selectDevice(try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"]), settings: settings)
        await store.capture(settings: settings)
        XCTAssertEqual(store.snapshot.packageName, "dev.composeinspect.sample")
        func selectCounter() throws -> Int {
            guard store.snapshot.packageName == "dev.composeinspect.sample" else { throw XCTSkip("Sample is not foreground") }
            let card = try XCTUnwrap(store.snapshot.nodes.first { $0.name == "ParameterCard" })
            store.select(card.id)
            XCTAssertEqual(store.selectedNodeID, card.id)
            return try XCTUnwrap(Int(try XCTUnwrap(card.observableFields.first { $0.name == "count" }).value))
        }
        let initial = try selectCounter()
        await store.verifyClick(expected: "Increment: \(initial)", settings: settings)
        XCTAssertTrue(store.verificationResult?.contains("预期文本已存在") == true, store.verificationResult ?? "")
        await store.verifyClick(expected: "Increment: \(initial + 1)", settings: settings)
        XCTAssertTrue(store.verificationResult?.contains("验证通过") == true, store.verificationResult ?? "")
        guard try selectCounter() == initial + 1 else { return XCTFail("Expected a single increment") }
        await store.verifyClick(expected: "unreachable-\(UUID())", settings: settings)
        XCTAssertTrue(store.verificationResult?.contains("条件等待超时") == true, store.verificationResult ?? "")
        XCTAssertEqual(try selectCounter(), initial + 2)
    }

}
