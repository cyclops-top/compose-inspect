import XCTest
@testable import ComposeInspectCore

final class SDKCaptureTests: XCTestCase {
    private func group(_ name: String?, y: Int = 20, children: [InspectorJSON] = [], parameters: [InspectorJSON] = []) -> InspectorJSON {
        .object(["name": name.map(InspectorJSON.string) ?? .null,
                 "boundsInWindow": .array([.number("10"), .number(String(y)), .number("110"), .number(String(y + 40))]),
                 "parameters": .array(parameters), "children": .array(children),
                 "source": .object(["file": .string("Screen.kt"), "line": .number("38"), "packageHash": .number("577838147")])])
    }
    private func response(tables: [InspectorJSON]? = nil, complete: Bool = true) -> InspectorJSON {
        let parameters: [InspectorJSON] = [
            .object(["name": .string("text"), "value": .object(["type": .string("java.lang.String"), "value": .string("Hello")])]),
            .object(["name": .string("spacing"), "inlineClass": .string("androidx.compose.ui.unit.Dp"),
                     "value": .object(["type": .string("java.lang.Float"), "value": .number("12")])]),
            .object(["name": .string("tint"), "inlineClass": .string("androidx.compose.ui.graphics.Color"),
                     "value": .object(["type": .string("java.lang.Long"), "value": .number("-281474976710656")])]),
            .object(["name": .string("callback"), "value": .object(["type": .string("Callback"), "opaque": .bool(true), "reason": .string("function")])]),
            .object(["name": .string("profile"), "value": .object(["type": .string("Profile"), "fields": .array([
                .object(["name": .string("age"), "value": .object(["type": .string("Int"), "value": .number("37")])])
            ])])])
        ]
        return .object(["protocolVersion": .number("1"), "packageName": .string("dev.sample"), "pid": .number("123"),
                        "complete": .bool(complete), "diagnostics": .array([]),
                        "windows": .array([.object(["screenOffset": .array([.number("30"), .number("50")]),
                            "tables": .array(tables ?? [.object(["tree": group(nil, children: [group("BasicText", parameters: parameters)])])])])])])
    }
    private func decode(_ response: InspectorJSON) throws -> InspectorSnapshot {
        try SDKSnapshotImporter.decode(Data(response.jsonString().utf8), imageSize: CGSize(width: 400, height: 600), packageName: "dev.sample")
    }

    func testSDKAdaptsToSharedModelAndKeepsRawValuesAndPointers() throws {
        let raw = response()
        let snapshot = try decode(raw)
        let text = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" })
        XCTAssertEqual(text.bounds, CGRect(x: 40, y: 70, width: 100, height: 40))
        XCTAssertEqual(text.source?.text, "Screen.kt:38")
        XCTAssertEqual(text.source?.packageHash, 577838147)
        XCTAssertEqual(text.label, "Hello")
        XCTAssertEqual(text.parameters.first { $0.name == "spacing" }?.value, "12dp")
        XCTAssertEqual(text.parameters.first { $0.name == "tint" }?.colorARGB, "FFFF0000")
        XCTAssertEqual(text.parameters.first { $0.name == "profile.age" }?.value, "37")
        XCTAssertEqual(text.parameters.first { $0.name == "callback" }?.isTruncated, true)
        XCTAssertTrue(text.parameters.allSatisfy { $0.continuationToken == nil })
        let doc = try XCTUnwrap(snapshot.document)
        XCTAssertEqual(doc.root["sdkCapture"], raw)
        XCTAssertEqual(doc.root.value(at: text.id)?["className"]?.string, "BasicText")
        let restored = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }

    func testPartialEmptyWrongPackageAndWrongProtocolAreRejected() throws {
        XCTAssertThrowsError(try decode(response(complete: false)))
        XCTAssertThrowsError(try decode(response(tables: [])))
        var fields = response().object!
        fields["packageName"] = .string("dev.other")
        XCTAssertThrowsError(try decode(.object(fields)))
        fields["packageName"] = .string("dev.sample"); fields["protocolVersion"] = .number("2")
        XCTAssertThrowsError(try decode(.object(fields)))
        XCTAssertThrowsError(try SDKInspectorClient.validateResponse(Data(response().jsonString().utf8), package: "dev.sample", expectedPID: 456))
    }

    func testTableOrderDoesNotChangePresentationGeometry() throws {
        let a = InspectorJSON.object(["tree": group("Item", y: 10)])
        let b = InspectorJSON.object(["tree": group("Item", y: 100)])
        XCTAssertTrue(InspectorClient.hasSameGeometry(try decode(response(tables: [a, b])), try decode(response(tables: [b, a]))))
    }

    func testIdenticalTableRootsWithDifferentDescendantsHaveStableOrder() throws {
        func table(_ text: String) -> InspectorJSON {
            let parameter = InspectorJSON.object(["name": .string("text"), "value": .object(["value": .string(text)])])
            let child = group("BasicText", parameters: [parameter])
            return .object(["tree": group("Wrapper", children: [child])])
        }
        let first = table("First"), second = table("Second")
        let baseline = try decode(response(tables: [first, second]))
        let reordered = try decode(response(tables: [second, first]))
        XCTAssertTrue(InspectorClient.hasSameGeometry(baseline, reordered))
        XCTAssertFalse(InspectorClient.hasSameGeometry(baseline, try decode(response(tables: [first, table("Changed")]))))
    }

    private func captured() -> CapturedSnapshot {
        let metadata = CaptureMetadata(serial: "device", packageName: "dev.sample", startedAt: Date(), finishedAt: Date(),
                                       includeFacets: "attributes", stableLayout: false, stableImage: false,
                                       diagnostics: ["inspector diagnostic"], baselineJSON: Data("original".utf8))
        return CapturedSnapshot(snapshot: InspectorSnapshot(packageName: "dev.sample", deviceName: "test", pixelSize: .zero, roots: [], captureMetadata: metadata),
                                imageData: Data([1, 2, 3]), aligned: false)
    }

    func testSDKSuccessNeverInvokesInspector() async throws {
        let expected = captured()
        let result = try await AutomaticCapture.capture(sdk: { expected }, inspector: {
            XCTFail("SDK success must not require Java/JAR")
            throw CommandFailure.failed("unexpected")
        })
        XCTAssertEqual(result.snapshot.id, expected.snapshot.id)
    }

    func testSDKFailureUsesIndependentInspectorResultAndRecordsReason() async throws {
        let expected = captured()
        let result = try await AutomaticCapture.capture(sdk: { throw CommandFailure.failed("incompatible protocol") }, inspector: { expected })
        XCTAssertEqual(result.imageData, expected.imageData)
        XCTAssertEqual(result.snapshot.id, expected.snapshot.id)
        XCTAssertEqual(result.snapshot.captureMetadata?.backend, .uiInspector)
        XCTAssertEqual(result.snapshot.captureMetadata?.baselineJSON, Data("original".utf8))
        XCTAssertTrue(result.snapshot.captureMetadata?.diagnostics.first?.contains("incompatible protocol") == true)
    }

    func testCancellationDoesNotFallBack() async throws {
        do {
            _ = try await AutomaticCapture.capture(sdk: { throw CancellationError() }, inspector: {
                XCTFail("Cancellation must not start inspector")
                throw CommandFailure.failed("unexpected")
            })
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testBothFailuresKeepBothDiagnostics() async throws {
        do {
            _ = try await AutomaticCapture.capture(sdk: { throw CommandFailure.failed("SDK timeout") },
                                                   inspector: { throw CommandFailure.failed("JAR missing") })
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SDK timeout"))
            XCTAssertTrue(error.localizedDescription.contains("JAR missing"))
        }
    }

    func testOldMetadataWithoutBackendStillDecodes() throws {
        let original = try XCTUnwrap(captured().snapshot.captureMetadata)
        let bytes = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(CaptureMetadata.self, from: bytes).backend)
    }
}
