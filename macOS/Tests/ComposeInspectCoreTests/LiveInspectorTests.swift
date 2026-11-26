import XCTest
@testable import ComposeInspectCore

final class LiveInspectorTests: XCTestCase {
    func testCaptureExplainsInstalledNonDebuggableBuild() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_LIVE"] == "1", let package = env["COMPOSEINSPECT_NONDEBUGGABLE_PACKAGE"] else {
            throw XCTSkip("Requires an installed non-debuggable package on the test device")
        }
        let tools = try InspectorToolchain(adb: URL(fileURLWithPath: XCTUnwrap(env["COMPOSEINSPECT_ADB"])),
                                           environment: env)
        let serial = try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"])
        do {
            _ = try await SDKInspectorClient(tools: tools).capture(serial: serial, package: package, deviceName: "Integration device")
            XCTFail("Expected capture to fail for the non-debuggable build")
        } catch CommandFailure.failed(let message) {
            XCTAssertTrue(message.contains("\(package) 是不可调试版本"), message)
            XCTAssertTrue(message.contains("debugImplementation"), message)
        }
    }

    func testSampleSourceOnlyCapture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_SOURCE_SAMPLE"] == "1" else { throw XCTSkip("Requires the current SDK sample main screen") }
        let tools = try InspectorToolchain(adb: URL(fileURLWithPath: XCTUnwrap(env["COMPOSEINSPECT_ADB"])), environment: env)
        let client = SDKInspectorClient(tools: tools)
        let serial = try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"])
        func capture(_ enabled: Bool, keys: [String]? = nil) async throws -> CapturedSnapshot {
            try await client.capture(serial: serial, package: "dev.composeinspect.sample", deviceName: "sample",
                                     windowImages: true, onlySourceNodes: enabled, sourceKeys: keys)
        }
        let full = try await capture(false)
        let project = try await capture(true, keys: ["577838147:MainActivity.kt"])
        let raw = try XCTUnwrap(project.snapshot.document?.root["sdkCapture"])
        XCTAssertEqual(raw["projectSourcesOnly"]?.boolean, true)
        let kept = project.snapshot.nodes.filter { $0.kind == "ComposeNode" }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(kept.allSatisfy { $0.source?.file == "MainActivity.kt" && $0.source?.packageHash == 577838147 })
        XCTAssertLessThan(kept.count, full.snapshot.nodes.filter { $0.kind == "ComposeNode" }.count)
        XCTAssertTrue(kept.contains { $0.name == "ParameterCard" && !$0.isClickable && $0.style == nil })
        let empty = try await capture(true, keys: [])
        let root = try XCTUnwrap(empty.snapshot.roots.first)
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertFalse(root.bounds.isEmpty)
        XCTAssertFalse(empty.windowImages.isEmpty && empty.imageData.isEmpty)
        let restored = try await capture(false)
        XCTAssertEqual(restored.snapshot.nodes.count, full.snapshot.nodes.count)
    }

    func testQuickCaptureOnPerformanceScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_QUICK_SAMPLE"] == "1" else {
            throw XCTSkip("Requires the SDK sample performance screen")
        }
        let adb = URL(fileURLWithPath: try XCTUnwrap(env["COMPOSEINSPECT_ADB"]))
        let client = SDKInspectorClient(tools: InspectorToolchain(adb: adb, environment: env))
        let serial = try XCTUnwrap(env["COMPOSEINSPECT_SERIAL"])
        func capture(keys: [String]? = nil) async throws -> CapturedSnapshot {
            try await client.capture(serial: serial, package: "dev.composeinspect.sample", deviceName: "sample",
                                     windowImages: true, onlySourceNodes: keys != nil, sourceKeys: keys)
        }
        do {
            let result = try await capture()
            let raw = try XCTUnwrap(result.snapshot.document?.root["sdkCapture"])
            XCTAssertEqual(raw["geometryOnly"]?.boolean, true)
            let layers = result.snapshot.nodes.filter { $0.name == "PerformanceLayer" }
            XCTAssertFalse(layers.isEmpty)
            XCTAssertTrue(layers.contains { !$0.bounds.isEmpty && $0.source?.file != nil })
            XCTAssertEqual(raw["stats"]?["parameters"]?.int64, 0)
            XCTAssertFalse(result.snapshot.nodes.contains { $0.style != nil })
            XCTAssertFalse(result.snapshot.nodes.contains { $0.isClickable })
            XCTAssertFalse(result.windowImages.isEmpty && result.imageData.isEmpty)
        }
        let project = try await capture(keys: ["577838147:MainActivity.kt"])
        let kept = project.snapshot.nodes.filter { $0.kind == "ComposeNode" }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(kept.allSatisfy { $0.source?.file == "MainActivity.kt" && $0.source?.packageHash == 577838147 })
    }

    func testConfiguredDeviceCapturePreservesOriginalDump() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_LIVE"] == "1" else { throw XCTSkip("Set COMPOSEINSPECT_LIVE=1 with explicit tool/target paths to run a real-device capture.") }
        func required(_ name: String) throws -> String { try XCTUnwrap(env[name], name) }
        let tools = try InspectorToolchain(adb: URL(fileURLWithPath: required("COMPOSEINSPECT_ADB")),
                                          environment: env)
        let client = SDKInspectorClient(tools: tools)
        let result = try await client.capture(serial: required("COMPOSEINSPECT_SERIAL"),
                                              package: required("COMPOSEINSPECT_PACKAGE"), deviceName: "Integration device")
        XCTAssertFalse(result.snapshot.nodes.isEmpty)
        XCTAssertTrue(result.snapshot.nodes.allSatisfy { $0.style == nil && !$0.isClickable })
        let document = try XCTUnwrap(result.snapshot.document)
        XCTAssertEqual(try InspectorJSON.parse(document.originalJSON), document.root)
        XCTAssertEqual(result.snapshot.roots.count, document.windows.count)
        XCTAssertNotNil(result.snapshot.captureMetadata)
        let restored = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(result.snapshot))
        XCTAssertEqual(restored.document?.originalJSON, document.originalJSON)
        XCTAssertEqual(restored.nodes.count, result.snapshot.nodes.count)
        if let directory = env["COMPOSEINSPECT_LIVE_OUTPUT"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try document.originalJSON.write(to: output.appendingPathComponent("tree.json"))
            try result.imageData.write(to: output.appendingPathComponent("screen.png"))
            try JSONEncoder().encode(result.snapshot.captureMetadata).write(to: output.appendingPathComponent("metadata.json"))
        }
    }
}
