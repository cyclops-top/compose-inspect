import XCTest
@testable import ComposeInspectCore

final class SDKStyleTests: XCTestCase {
    private func table(color: String) throws -> InspectorJSON {
        try InspectorJSON.parse(Data("""
        {"hostView":"AndroidComposeView","tree":{"name":"BasicText","boundsInWindow":[10,20,110,60],
         "parameters":[],"children":[]},"styleCatalog":{"version":1,"density":2,"diagnostics":[],"records":[{
         "contentBounds":{"x":40,"y":70,"width":100,"height":40},
         "outerBounds":{"x":30,"y":50,"width":130,"height":90},"layers":[
          {"name":"BackgroundElement","kind":"background","bounds":{"x":30,"y":50,"width":130,"height":90},
           "argb":"\(color)","alpha":0.5,"shape":{"name":"RoundedCornerShape","kind":"rounded",
             "radiiPx":{"topLeft":24,"topRight":12,"bottomLeft":8,"bottomRight":4},
             "corners":{"topLeft":{"value":12,"unit":"dp"}}}},
          {"name":"PaddingElement","kind":"padding","bounds":{"x":30,"y":50,"width":130,"height":90},
           "padding":{"left":5,"top":10,"right":10,"bottom":15}}
        ]}]}}
        """.utf8))
    }

    private func decode(_ tables: [InspectorJSON]) throws -> InspectorSnapshot {
        let catalogs = tables.compactMap { $0["styleCatalog"] }
        let indexed = tables.enumerated().map { index, table in
            var fields = table.object!
            fields.removeValue(forKey: "styleCatalog")
            fields["styleCatalogIndex"] = .number(String(index))
            return InspectorJSON.object(fields)
        }
        let response: InspectorJSON = .object([
            "protocolVersion": .number("1"), "packageName": .string("dev.sample"), "pid": .number("1"),
            "complete": .bool(true), "diagnostics": .array([]), "windows": .array([.object([
                "screenOffset": .array([.number("30"), .number("50")]), "tables": .array(indexed),
                "styleCatalogs": .array(catalogs)
            ])])
        ])
        return try SDKSnapshotImporter.decode(Data(response.jsonString().utf8), imageSize: CGSize(width: 400, height: 600), packageName: "dev.sample")
    }

    func testLayoutIdentityDisambiguatesEqualRectangles() throws {
        var raw = try table(color: "FFF6F6F6").object!
        var tree = raw["tree"]!.object!
        tree["kind"] = .string("layout")
        tree["layoutIdentity"] = .number("42")
        raw["tree"] = .object(tree)
        var catalog = raw["styleCatalog"]!.object!
        var styled = catalog["records"]!.array![0].object!
        styled["layoutIdentity"] = .number("42")
        var empty = styled
        empty["layoutIdentity"] = .number("43")
        empty["layers"] = .array([])
        catalog["records"] = .array([.object(empty), .object(styled)])
        raw["styleCatalog"] = .object(catalog)
        let snapshot = try decode([.object(raw)])
        XCTAssertEqual(snapshot.nodes.first { $0.name == "BasicText" }?.style?.layers.first?.argb, "FFF6F6F6")
    }

    func testRotatedAnonymousLayoutUsesMeasuredBoundsForTextAndPicking() throws {
        var raw = try table(color: "FFFFFFFF").object!
        var tree = raw["tree"]!.object!
        // 90-degree rotation: tooling keeps 100x40 at the transformed origin;
        // the four transformed corners occupy 40x100 to its left instead.
        let measured: InspectorJSON = .object(["x": .number("0"), "y": .number("70"),
            "width": .number("40"), "height": .number("100")])
        tree["children"] = .array([.object([
            "kind": .string("layout"), "name": .null, "layoutIdentity": .number("42"),
            "boundsInWindow": tree["boundsInWindow"]!, "parameters": .array([]), "children": .array([])
        ])])
        raw["tree"] = .object(tree)
        var catalog = raw["styleCatalog"]!.object!
        let record: InspectorJSON = .object(["layoutIdentity": .number("42"),
            "contentBounds": measured, "outerBounds": measured, "layers": .array([])])
        catalog["records"] = .array([record])
        raw["styleCatalog"] = .object(catalog)
        let snapshot = try decode([.object(raw)])
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" })
        let expected = CGRect(x: 0, y: 70, width: 40, height: 100)
        XCTAssertEqual(node.bounds, expected)
        XCTAssertEqual(node.style?.contentBounds, expected)
        let index = InspectorSnapshotIndex(snapshot)
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: snapshot.pixelSize)
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: 20, y: 150), in: index,
            imageSize: snapshot.pixelSize).contains { $0.id == node.id })
        XCTAssertFalse(mapper.candidates(at: CGPoint(x: 100, y: 90), in: index,
            imageSize: snapshot.pixelSize).contains { $0.id == node.id })

        // Without layout identity, unequal rectangles must not borrow another layout's bounds.
        tree["children"] = .array([])
        raw["tree"] = .object(tree)
        let unowned = try decode([.object(raw)]).nodes.first { $0.name == "BasicText" }
        XCTAssertNil(unowned?.style)
        XCTAssertEqual(unowned?.bounds, CGRect(x: 40, y: 70, width: 100, height: 40))
    }

    func testMeasuredStylesKeepScreenCoordinatesUnitsAndRawCatalog() throws {
        let snapshot = try decode([table(color: "80445566")])
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" })
        let style = try XCTUnwrap(node.style)
        XCTAssertEqual(style.contentBounds, CGRect(x: 40, y: 70, width: 100, height: 40))
        XCTAssertEqual(node.bounds, CGRect(x: 30, y: 50, width: 130, height: 90))
        XCTAssertEqual(style.totalPadding, .init(left: 5, top: 10, right: 10, bottom: 15))
        XCTAssertEqual(style.layers.map(\.kind), ["background", "padding"])
        XCTAssertEqual(style.layers[0].argb, "80445566")
        XCTAssertEqual(style.layers[0].alpha, 0.5)
        XCTAssertEqual(style.layers[0].shape?.topLeft, 24)
        XCTAssertEqual(style.layers[0].shape?.corners?["topLeft"]?.label, "12dp")
        XCTAssertEqual(snapshot.document?.root["sdkCapture"]?["windows"]?.array?.first?["styleCatalogs"]?.array?.first?["version"]?.int64, 1)
    }

    func testCatalogsNeverAssociateAcrossHostsWithIdenticalBounds() throws {
        let snapshot = try decode([table(color: "FFFF0000"), table(color: "FF0000FF")])
        let nodes = snapshot.nodes.filter { $0.name == "BasicText" }
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(Set(nodes.compactMap { $0.style?.layers.first?.argb }), ["FFFF0000", "FF0000FF"])
    }

    func testBothAdaptersProduceTheSameTreeParametersAndStyles() throws {
        var sdkTable = try table(color: "80445566").object!
        var sdkNode = sdkTable["tree"]!.object!
        sdkNode["parameters"] = .array([
            .object(["name": .string("text"), "value": .object(["type": .string("java.lang.String"), "value": .string("Hello")])]),
            .object(["name": .string("spacing"), "inlineClass": .string("androidx.compose.ui.unit.Dp"),
                     "value": .object(["type": .string("java.lang.Float"), "value": .number("12")])])
        ])
        sdkNode["source"] = .object(["file": .string("Screen.kt"), "line": .number("38")])
        sdkTable["tree"] = .object(sdkNode)
        let sdk = try decode([.object(sdkTable)])
        let content: InspectorJSON = .object(["x": .number("40"), "y": .number("70"),
                                              "width": .number("100"), "height": .number("40")])
        let leaf: InspectorJSON = .object([
            "type": .string("ComposeNode"), "id": .number("1"), "className": .string("BasicText"),
            "bounds": content, "children": .array([]),
            "sourceLocation": .object(["fileName": .string("Screen.kt"), "lineNumber": .number("38")]),
            "parameters": .array([
                .object(["name": .string("text"), "value": .string("Hello")]),
                .object(["name": .string("spacing"), "value": .object(["value": .number("12"), "unit": .string("DP")])])
            ])
        ])
        let host: InspectorJSON = .object([
            "type": .string("ViewNode"), "id": .number("2"), "className": .string("AndroidComposeView"),
            "bounds": content, "children": .array([leaf]), "attributes": .array([
                .object(["name": .string(UIInspectorSnapshotAdapter.styleAttribute),
                         "value": .string(sdkTable["styleCatalog"]!.jsonString())])
            ])
        ])
        let raw: InspectorJSON = .object(["windows": .array([.object(["root": .object([
            "type": .string("ViewNode"), "id": .number("3"), "className": .string("Window"),
            "bounds": content, "children": .array([host])
        ])])])])
        let bytes = Data(raw.jsonString().utf8)
        let inspector = try SnapshotImporter.decode(bytes, imageSize: CGSize(width: 400, height: 600), packageName: "dev.sample")
        XCTAssertTrue(InspectorClient.hasSameGeometry(sdk, inspector))
        XCTAssertEqual(sdk.nodes.count, inspector.nodes.count)
        for (a, b) in zip(sdk.nodes, inspector.nodes) {
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.label, b.label)
            XCTAssertEqual(a.source, b.source)
            XCTAssertEqual(a.bounds, b.bounds)
            XCTAssertEqual(a.style, b.style)
            XCTAssertEqual(a.parameters.map(\.name), b.parameters.map(\.name))
            XCTAssertEqual(a.parameters.map(\.value), b.parameters.map(\.value))
            XCTAssertEqual(a.parameters.map(\.group), b.parameters.map(\.group))
            XCTAssertEqual(a.parameters.map(\.isTruncated), b.parameters.map(\.isTruncated))
            XCTAssertEqual(sdk.document?.root.value(at: a.id)?["className"]?.string, a.name)
            XCTAssertEqual(inspector.document?.root.value(at: b.id)?["className"]?.string, b.name)
        }
        XCTAssertEqual(inspector.document?.originalJSON, bytes)
        XCTAssertNotNil(sdk.document?.root["sdkCapture"])
    }

    func testLocalDensityAndStyleDiagnosticsSurviveImport() throws {
        var raw = try table(color: "FFFF0000").object!
        var catalog = raw["styleCatalog"]!.object!
        var record = catalog["records"]!.array![0].object!
        record["density"] = .number("3")
        catalog["records"] = .array([.object(record)])
        catalog["diagnostics"] = .array([.string("Unsupported modifier on another layout")])
        raw["styleCatalog"] = .object(catalog)
        let snapshot = try decode([.object(raw)])
        XCTAssertEqual(snapshot.nodes.first { $0.name == "BasicText" }?.style?.density, 3)
        XCTAssertTrue(snapshot.nodes.contains { $0.parameters.contains { $0.name == "样式采集限制" } })
    }

    func testLiveSDKStyleProbe() throws {
        guard let path = ProcessInfo.processInfo.environment["SDK_STYLE_CAPTURE"] else {
            throw XCTSkip("Set SDK_STYLE_CAPTURE to the captured sample styles scenario")
        }
        let snapshot = try SDKSnapshotImporter.decode(Data(contentsOf: URL(fileURLWithPath: path)),
            imageSize: CGSize(width: 1920, height: 1080), packageName: "dev.composeinspect.sample")
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" && $0.label == "style-layered" })
        let style = try XCTUnwrap(node.style)
        XCTAssertEqual(style.layers.map(\.kind), ["background", "padding", "clip", "background", "padding"])
        XCTAssertEqual(style.layers[0].argb, "FF112233")
        XCTAssertEqual(style.layers[3].argb, "80445566")
        XCTAssertEqual(style.layers[0].shape?.topLeft, 12 * style.density)
        XCTAssertEqual(style.layers[2].shape?.kind, "cut")
        XCTAssertEqual(style.totalPadding, .init(left: 10, top: 16, right: 16, bottom: 22))
        XCTAssertEqual(node.bounds, style.outerBounds)
        XCTAssertGreaterThan(style.outerBounds.width, style.contentBounds.width)
        for (label, padding, left, right) in [
            ("style-rtl", ComponentStyle.Insets(left: 9, top: 4, right: 3, bottom: 5), 6.0, 2.0),
            ("style-absolute", ComponentStyle.Insets(left: 3, top: 4, right: 9, bottom: 5), 2.0, 6.0)
        ] {
            let value = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" && $0.label == label }?.style)
            XCTAssertEqual(value.totalPadding, padding)
            XCTAssertEqual(value.layers.first?.shape?.topLeft, left * value.density)
            XCTAssertEqual(value.layers.first?.shape?.topRight, right * value.density)
        }
        XCTAssertTrue(snapshot.nodes.contains { $0.style?.layers.contains { $0.unsupported?.contains("brush") == true } == true })
    }
}
