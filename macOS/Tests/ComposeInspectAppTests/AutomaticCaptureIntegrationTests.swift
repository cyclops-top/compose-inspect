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
        let settings = ToolchainSettings(defaults: defaults, environment: [:])
        settings.adbOverride = adb.path
        settings.javaOverride = "/missing/java"
        settings.inspectorJarOverride = "/missing/ui-inspector.jar"
        await settings.checkStartupEnvironment()
        XCTAssertFalse(settings.showEnvironmentSetup)
        XCTAssertTrue(settings.startupEnvironmentProblems.isEmpty)
        XCTAssertNoThrow(try settings.resolvedTools(requireJava: false))
        XCTAssertThrowsError(try settings.resolvedTools())
    }

    /// Runs the real foreground-target -> SDK/fallback -> shared workspace pipeline.
    /// With expected=sdk, intentionally invalid Java/JAR prove they aren't prerequisites.
    func testConfiguredForegroundCaptureUsesExpectedBackendAndSharedInteractions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_AUTO_LIVE"] == "1" else { throw XCTSkip("Explicit real-device auto capture opt-in required") }
        _ = NSApplication.shared
        let expected = try XCTUnwrap(CaptureBackend(rawValue: try XCTUnwrap(env["COMPOSEINSPECT_EXPECT_BACKEND"])))
        let suite = "sdk-live-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ToolchainSettings(defaults: defaults, environment: env)
        settings.adbOverride = try XCTUnwrap(env["COMPOSEINSPECT_ADB"])
        settings.javaOverride = expected == .sdk ? "/missing/java" : try XCTUnwrap(env["COMPOSEINSPECT_JAVA"])
        settings.inspectorJarOverride = expected == .sdk ? "/missing/jar" : try XCTUnwrap(env["COMPOSEINSPECT_JAR"])
        settings.verifyCaptureConsistency = env["COMPOSEINSPECT_SINGLE_CAPTURE"] != "1"
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
        XCTAssertEqual(store.snapshot.captureMetadata?.backend, expected)
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
}
