import XCTest
import CoreGraphics
@testable import ComposeInspectCore

final class FullJSONTests: XCTestCase {
    private let fixture = #"""
    {
      "futureRoot":{"version":99999999999999999999999999999999999999999,"enabled":true},
      "windows":[{"futureWindow":[1,false,null],
        "root":{"type":"ViewNode","id":1,"className":"AndroidComposeView","bounds":{"x":0,"y":0,"width":1080,"height":2220},
          "attributes":[{"name":"样式采集限制","value":"未知绘制层","futureAttribute":42}],
          "children":[{"type":"ComposeNode","id":9223372036854775806,"className":"Button","bounds":{"x":84,"y":120,"width":912,"height":144},
            "sourceLocation":{"fileName":"Login.kt","lineNumber":86,"futureSource":"x"},"futureNode":{"a/b~":["😀",-0,1e400]},
            "parameters":[{"name":"modifier","elements":[{"name":"height","value":{"value":48.123456789123456789,"unit":"DP"}}]},
              {"name":"nil","value":null},{"name":"empty","value":"List[0]","isCollection":true,"elements":[]},
              {"name":"items","value":"List[7]","isCollection":true,"isTruncated":true,
               "elements":[{"name":"[0]","value":"one"},{"name":"[1]","isTruncated":true,"elements":[]}]},
              {"name":"color","value":"#FF010203"},{"name":"future","value":{"unrecognized":[false,null,1.0000000000000000000001]}}],
            "unmergedSemantics":[{"name":"OnClick","value":true}]}]}},
        {"root":{"type":"FutureNode","id":-3,"className":"Popup","bounds":{"x":2,"y":3,"width":4,"height":5},"extension":true}}]
    }
    """#

    func testEntireDocumentAndUnknownFieldsSurviveArchiveByteForByte() throws {
        let bytes = Data(fixture.utf8)
        let document = try InspectorDocument(data: bytes)
        let archive = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(InspectorDocument.self, from: archive)
        XCTAssertEqual(restored.originalJSON, bytes)
        XCTAssertEqual(restored.root, document.root)
        XCTAssertEqual(try InspectorJSON.parse(Data(document.root.jsonString(pretty: true).utf8)), document.root)
        XCTAssertEqual(document.root["futureRoot"]?["version"]?.display, "99999999999999999999999999999999999999999")
    }

    func testWindowsAndUnknownNodeKindsAreRetained() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: Data(fixture.utf8)), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let document = try XCTUnwrap(snapshot.document)
        XCTAssertEqual(document.windows.count, 2)
        XCTAssertEqual(snapshot.roots[1].kind, "FutureNode")
        XCTAssertEqual(snapshot.roots[1].rawID, -3)
    }

    func testParametersWithoutValueNullCollectionsAndNestedValues() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: Data(fixture.utf8)), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let node = snapshot.nodes[1]
        XCTAssertEqual(node.rawID, 9223372036854775806)
        XCTAssertEqual(node.parameters.count, 10)
        XCTAssertTrue(node.parameters.contains { $0.name == "modifier" && $0.original?["value"] == nil })
        XCTAssertEqual(node.parameters.first { $0.name == "nil" }?.original?["value"], .null)
        XCTAssertEqual(node.parameters.first { $0.name == "empty" }?.original?["elements"]?.array, [])
        XCTAssertEqual(node.parameters.first { $0.name == "modifier.height" }?.value, "48.123456789123456789dp")
    }

    func testUnknownFieldsAndEscapedNodePointersRemainAccessible() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: Data(fixture.utf8)), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let parameter = try XCTUnwrap(snapshot.roots[0].parameters.first)
        XCTAssertEqual(parameter.original?["futureAttribute"]?.int64, 42)
        let node = snapshot.nodes[1]
        XCTAssertEqual(snapshot.document?.root.value(at: node.id + "/futureNode/a~1b~0")?.array,
                       [.string("😀"), .number("-0"), .number("1e400")])
    }

    func testSnapshotArchiveRoundTripIncludesOriginalDumpAndOptionalNewFields() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: Data(fixture.utf8)), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let restored = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.document?.originalJSON, Data(fixture.utf8))
    }

    func testCaptureContextPreservesParsedTreeOriginalBytesAndIdentity() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: Data(fixture.utf8)), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let metadata = CaptureMetadata(serial: "device", packageName: "app.example", startedAt: Date(), finishedAt: Date(),
                                      diagnostics: ["diagnostic"], baselineJSON: Data(fixture.utf8))
        let result = snapshot.withCaptureContext(deviceName: "Pixel", metadata: metadata)
        XCTAssertEqual(result.id, snapshot.id)
        XCTAssertEqual(result.capturedAt, snapshot.capturedAt)
        XCTAssertEqual(result.roots, snapshot.roots)
        XCTAssertEqual(result.document, snapshot.document)
        XCTAssertEqual(result.document?.originalJSON, Data(fixture.utf8))
        XCTAssertEqual(result.deviceName, "Pixel")
        XCTAssertEqual(result.captureMetadata, metadata)
    }

    func testInvalidJSONIsRejectedInsteadOfPartlyAccepted() {
        for bad in ["01", "[1,]", "{\"x\":1,}", "NaN", "1e", "1.", "true false", "\"unterminated", "[null"] {
            XCTAssertThrowsError(try InspectorJSON.parse(Data(bad.utf8)), bad)
        }
    }

    func testConfiguredADBPrecedesGlobalSDK() {
        let tools = InspectorToolchain(adb: URL(fileURLWithPath: "/my sdk/platform-tools/adb"),
                                       environment: ["ANDROID_HOME": "/wrong", "PATH": "/usr/bin"])
        XCTAssertNil(tools.environment["JAVA_HOME"])
        XCTAssertEqual(tools.environment["ANDROID_HOME"], "/my sdk")
        XCTAssertTrue(tools.environment["PATH"]!.hasPrefix("/my sdk/platform-tools:"))
        XCTAssertFalse(InspectorClient.validPackage("app.example; rm -rf /"))
        XCTAssertTrue(InspectorClient.validPackage("top.cyclops.reader"))
    }

    func testCommandRunnerBinaryDataAndArgumentsAreNotShellExpanded() async throws {
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/printf"),
                                                 arguments: ["%s", "$(echo injected) `echo bad` 中文"],
                                                 environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "$(echo injected) `echo bad` 中文")
    }

    func testCommandTimeoutAndCancellationStopOnlyTheirOwnProcess() async throws {
        do {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch CommandFailure.timedOut {} catch { XCTFail("Unexpected error: \(error)") }
        let task = Task { try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    func testDeviceStatesAreNotMistakenForOnlineDevices() {
        let devices = ADBDevice.parse("List of devices attached\nemulator-5554 device model:Pixel_9 transport_id:1\nabc unauthorized\nxyz offline\n")
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "abc", "xyz"])
        XCTAssertEqual(devices.filter(\.online).count, 1)
    }
}
