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
            "protocolVersion": .number("1"), "sdkVersion": .string("0.1.3"), "packageName": .string("dev.sample"), "pid": .number("1"),
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

    func testSharedCatalogSurvivesNormalizationAndLegacyInlineCatalogStillImports() throws {
        let table = try table(color: "FF112233")
        let catalog = try XCTUnwrap(table["styleCatalog"])
        var indexed = try XCTUnwrap(table.object)
        indexed.removeValue(forKey: "styleCatalog")
        indexed["styleCatalogIndex"] = .number("0")
        let offset = InspectorJSON.array([.number("30"), .number("50")])
        let sdk: InspectorJSON = .object(["complete": .bool(true), "diagnostics": .array([]), "windows": .array([
            .object(["screenOffset": offset, "tables": .array([])]),
            .object(["screenOffset": offset, "tables": .array([.object(indexed), .object(indexed)]),
                     "styleCatalogs": .array([catalog])])
        ])])
        let size = CGSize(width: 400, height: 600)
        let snapshot = try SDKSnapshotImporter.decode(InspectorDocument(root: sdk), imageSize: size, packageName: "dev.sample")
        let document = try XCTUnwrap(snapshot.document)
        let window = try XCTUnwrap(document.windows.first)
        XCTAssertEqual(window["sdkWindow"]?["captureIndex"], .number("1"))
        let hosts = try XCTUnwrap(window["root"]?["children"]?.array)
        XCTAssertEqual(hosts.count, 2)
        for host in hosts {
            XCTAssertNil(host["styleCatalog"])
            XCTAssertEqual(host["styleCatalogIndex"], .number("0"))
        }
        let colors = snapshot.nodes.filter { $0.name == "BasicText" }.map { $0.style?.layers.first?.argb }
        XCTAssertEqual(colors, ["FF112233", "FF112233"])

        var legacyHost = try XCTUnwrap(hosts.first?.object)
        legacyHost.removeValue(forKey: "styleCatalogIndex")
        legacyHost["styleCatalog"] = catalog
        let legacy = InspectorDocument(root: .object(["windows": .array([.object(["root": .object(legacyHost)])])]))
        let restored = try SnapshotImporter.decode(legacy, imageSize: size, packageName: "dev.sample")
        XCTAssertEqual(restored.nodes.last?.style?.layers.first?.argb, "FF112233")
    }

    func testCatalogsNeverAssociateAcrossHostsWithIdenticalBounds() throws {
        let snapshot = try decode([table(color: "FFFF0000"), table(color: "FF0000FF")])
        let nodes = snapshot.nodes.filter { $0.name == "BasicText" }
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(Set(nodes.compactMap { $0.style?.layers.first?.argb }), ["FFFF0000", "FF0000FF"])
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
