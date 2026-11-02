import XCTest
import CoreGraphics
@testable import ComposeInspectCore

final class FullJSONTests: XCTestCase {
    private let fixture = #"""
    {
      "futureRoot":{"version":99999999999999999999999999999999999999999,"enabled":true},
      "displays":[{"id":0,"widthPx":1080,"heightPx":2220,"orientation":90,"futureDisplay":null},{"id":2,"widthPx":800,"heightPx":600}],
      "windows":[{"theme":"@style/AppTheme","futureWindow":[1,false,null],
        "configuration":{"colorModeHdr":"yes","colorModeWideGamut":"yes","countryCode":460,"density":480,"fontScale":1.23456789123456789,
          "grammaticalGender":"neutral","hardKeyboardHidden":"yes","keyboard":"qwerty","keyboardHidden":"no","layoutDirection":"rtl",
          "locale":"zh_CN_Hans","navigation":"nonav","navigationHidden":"yes","networkCode":1,"orientation":"landscape",
          "screenHeightDp":360,"screenLayoutLong":"yes","screenLayoutRound":"no","screenLayoutSize":"normal","screenWidthDp":740,
          "smallestScreenWidthDp":360,"touchScreen":"finger","uiModeNight":"yes","uiModeType":"normal","futureConfig":"原样保留"},
        "root":{"type":"ViewNode","id":1,"className":"android.widget.FrameLayout","idResource":"app:id/root","layoutResource":"app:layout/main",
          "bounds":{"x":0,"y":0,"width":1080,"height":2220},
          "attributes":[{"name":"width","value":{"value":144,"dp":48.0000001,"sp":47.9},"directSource":"layout/main.xml:8","styleChain":["A","B"],"futureAttribute":42},
                        {"name":"visible","value":true},{"name":"nil","value":null}],
          "children":[{"type":"ComposeNode","id":9223372036854775806,"className":"Button","bounds":{"x":84,"y":120,"width":912,"height":144},
            "sourceLocation":{"fileName":"Login.kt","lineNumber":86,"futureSource":"x"},"futureNode":{"a/b~":["😀",-0,1e400]},
            "parameters":[{"name":"modifier","elements":[{"name":"height","value":{"value":48.123456789123456789,"unit":"DP"}}]},
              {"name":"nil","value":null},{"name":"empty","value":"List[0]","isCollection":true,"elements":[]},
              {"name":"items","value":"List[7]","isCollection":true,"isTruncated":true,"continuationToken":"opaque:do/not/decode",
               "elements":[{"name":"[0]","value":"one"},{"name":"[1]","isTruncated":true,"continuationToken":"nested","elements":[]}]},
              {"name":"resource","value":{"namespace":"app","type":"string","name":"login"}},
              {"name":"lambda","value":{"fileName":"Login.kt","startLineNumber":87}},
              {"name":"color","value":"#FF010203"},{"name":"future","value":{"unrecognized":[false,null,1.0000000000000000000001]}}],
            "mergedSemantics":[{"name":"text","value":"登录"}],"unmergedSemantics":[{"name":"text","value":"本节点"}]}]}},
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

    func testAllWindowsDisplaysConfigurationAndResourcesAreRetained() throws {
        let snapshot = try SnapshotImporter.decode(Data(fixture.utf8), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let document = try XCTUnwrap(snapshot.document)
        XCTAssertEqual(document.displays.count, 2)
        XCTAssertEqual(document.windows.count, 2)
        XCTAssertEqual(document.windows[0]["configuration"]?["fontScale"]?.display, "1.23456789123456789")
        XCTAssertEqual(document.windows[0]["configuration"]?.object?.count, 25)
        XCTAssertEqual(document.windows[0]["theme"]?.string, "@style/AppTheme")
        XCTAssertEqual(snapshot.roots[0].idResource, "app:id/root")
        XCTAssertEqual(snapshot.roots[0].layoutResource, "app:layout/main")
        XCTAssertEqual(snapshot.roots[1].kind, "FutureNode")
        XCTAssertEqual(snapshot.roots[1].rawID, -3)
    }

    func testParametersWithoutValueNullCollectionsTokensAndBothSemantics() throws {
        let snapshot = try SnapshotImporter.decode(Data(fixture.utf8), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let node = snapshot.nodes[1]
        XCTAssertEqual(node.rawID, 9223372036854775806)
        XCTAssertEqual(node.parameters.count, 13)
        XCTAssertTrue(node.parameters.contains { $0.name == "modifier" && $0.original?["value"] == nil })
        XCTAssertEqual(node.parameters.first { $0.name == "nil" }?.original?["value"], .null)
        XCTAssertEqual(node.parameters.first { $0.name == "empty" }?.original?["elements"]?.array, [])
        XCTAssertEqual(node.parameters.first { $0.name == "items" }?.continuationToken, "opaque:do/not/decode")
        XCTAssertEqual(node.parameters.first { $0.name == "items.[1]" }?.continuationToken, "nested")
        XCTAssertEqual(node.parameters.first { $0.name == "modifier.height" }?.value, "48.123456789123456789dp")
        let semantics = node.parameters.filter { $0.name == "text" }
        XCTAssertEqual(Set(semantics.map(\.group)), [.mergedSemantics, .unmergedSemantics])
        XCTAssertEqual(Set(semantics.map(\.id)).count, 2)
    }

    func testAttributeSourcesChainsAndTypedValuesAreNotFlattenedAway() throws {
        let snapshot = try SnapshotImporter.decode(Data(fixture.utf8), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let parameter = try XCTUnwrap(snapshot.roots[0].parameters.first)
        XCTAssertEqual(parameter.original?["directSource"]?.string, "layout/main.xml:8")
        XCTAssertEqual(parameter.original?["styleChain"]?.array, [.string("A"), .string("B")])
        XCTAssertEqual(parameter.original?["value"]?["dp"]?.display, "48.0000001")
        XCTAssertEqual(parameter.original?["futureAttribute"]?.int64, 42)
        let node = snapshot.nodes[1]
        XCTAssertEqual(snapshot.document?.root.value(at: node.id + "/futureNode/a~1b~0")?.array,
                       [.string("😀"), .number("-0"), .number("1e400")])
    }

    func testSnapshotArchiveRoundTripIncludesOriginalDumpAndOptionalNewFields() throws {
        let snapshot = try SnapshotImporter.decode(Data(fixture.utf8), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        let restored = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.document?.originalJSON, Data(fixture.utf8))
    }

    func testCaptureContextPreservesParsedTreeOriginalBytesAndIdentity() throws {
        var snapshot = try SnapshotImporter.decode(Data(fixture.utf8), imageSize: CGSize(width: 1080, height: 2220), packageName: "app.example")
        snapshot.parameterReads = [ParameterRead(nodeID: "node", parameterID: "parameter", token: "token",
                                                 document: try InspectorDocument(data: Data("{}".utf8)))]
        let metadata = CaptureMetadata(serial: "device", packageName: "app.example", startedAt: Date(), finishedAt: Date(),
                                      includeFacets: "attributes", stableLayout: true, stableImage: false,
                                      diagnostics: ["diagnostic"], baselineJSON: Data(fixture.utf8))
        let result = snapshot.withCaptureContext(deviceName: "Pixel", metadata: metadata)
        XCTAssertEqual(result.id, snapshot.id)
        XCTAssertEqual(result.capturedAt, snapshot.capturedAt)
        XCTAssertEqual(result.roots, snapshot.roots)
        XCTAssertEqual(result.document, snapshot.document)
        XCTAssertEqual(result.document?.originalJSON, Data(fixture.utf8))
        XCTAssertEqual(result.parameterReads, snapshot.parameterReads)
        XCTAssertEqual(result.deviceName, "Pixel")
        XCTAssertEqual(result.captureMetadata, metadata)
    }

    func testInvalidJSONIsRejectedInsteadOfPartlyAccepted() {
        for bad in ["01", "[1,]", "{\"x\":1,}", "NaN", "1e", "1.", "true false", "\"unterminated", "[null"] {
            XCTAssertThrowsError(try InspectorJSON.parse(Data(bad.utf8)), bad)
        }
    }

    func testConfiguredToolsDoNotUseBundledJavaOrGlobalSDKByAccident() {
        let tools = InspectorToolchain(adb: URL(fileURLWithPath: "/my sdk/platform-tools/adb"),
                                       java: URL(fileURLWithPath: "/my jdk/bin/java"), jar: URL(fileURLWithPath: "/app/ui-inspector.jar"),
                                       environment: ["JAVA_HOME": "/wrong", "ANDROID_HOME": "/wrong", "PATH": "/usr/bin"])
        XCTAssertEqual(tools.environment["JAVA_HOME"], "/my jdk")
        XCTAssertEqual(tools.environment["ANDROID_HOME"], "/my sdk")
        XCTAssertTrue(tools.environment["PATH"]!.hasPrefix("/my sdk/platform-tools:/my jdk/bin:"))
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
