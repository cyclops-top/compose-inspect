import XCTest
@testable import ComposeInspectCore

final class ShapeAssociationTests: XCTestCase {
    private func snapshot(shape: String = "RoundedCornerShape", group: String = "unmergedSemantics",
                          radius: Double = 42, conflicting: Bool = false, unit: String = "DP", value: Double = 16, stringValue: Bool = false) throws -> InspectorSnapshot {
        let bounds = ["x": 42, "y": 554, "width": 996, "height": 323]
        let outer = ["x": 0, "y": 554, "width": 1080, "height": 323]
        let radii = ["topLeft": radius, "topRight": radius, "bottomLeft": radius, "bottomRight": radius]
        let layer: [String: Any] = ["name": "BackgroundElement", "kind": "background", "bounds": bounds,
            "argb": "FFFFFFFF", "alpha": 1, "shape": ["name": "RoundedCornerShape", "kind": shape.contains("Cut") ? "cut" : "rounded", "radiiPx": radii,
                "corners": ["topLeft": ["value": value, "unit": unit == "DP" ? "dp" : unit]]]]
        var styled: [String: Any] = ["contentBounds": bounds, "outerBounds": bounds, "layers": [layer]]
        let padded: [String: Any] = ["contentBounds": bounds, "outerBounds": outer, "layers": [
            ["name": "PaddingElement", "kind": "padding", "bounds": outer,
             "padding": ["left": 16, "right": 16, "top": 0, "bottom": 0]]]]
        var records = [padded, styled]
        if conflicting {
            var other = layer; other["argb"] = "FFFF0000"
            styled["layers"] = [other]; records.append(styled)
        }
        let catalog = try JSONSerialization.data(withJSONObject: ["version": 1, "density": 2.625, "records": records])
        var evidence: [String: Any] = ["name": "Shape", "value": shape]
        if shape != "CircleShape" {
            let keys = shape.hasPrefix("Absolute") ? ["topLeft", "topRight", "bottomLeft", "bottomRight"] : ["topStart", "topEnd", "bottomStart", "bottomEnd"]
            evidence["elements"] = keys.map {
                ["name": $0, "value": stringValue ? "\(value)\(unit)" as Any : ["value": value, "unit": unit] as Any] as [String: Any]
            }
        }
        let surface: [String: Any] = ["id": 2, "type": "ComposeNode", "className": "Surface", "bounds": bounds,
            "sourceLocation": ["fileName": "ResidentCard.kt", "lineNumber": 44], group: [evidence]]
        let root: [String: Any] = ["id": 1, "type": "ViewNode", "className": "AndroidComposeView", "bounds": outer,
            "attributes": [["name": UIInspectorSnapshotAdapter.styleAttribute, "value": String(decoding: catalog, as: UTF8.self)]], "children": [surface]]
        let data = try JSONSerialization.data(withJSONObject: ["windows": [["root": root]]])
        return try SnapshotImporter.decode(data, imageSize: CGSize(width: 1080, height: 2400), packageName: "test.app")
    }

    func testOwnShapeDisambiguatesSurfaceFromSameBoundsPaddingWrapper() throws {
        let snapshot = try snapshot()
        let node = try XCTUnwrap(snapshot.nodes.last)
        let style = try XCTUnwrap(node.style)
        XCTAssertEqual(style.layers.first?.shape?.topLeft, 42)
        XCTAssertEqual((style.layers.first?.shape?.topLeft ?? 0) / style.density, 16)
        XCTAssertEqual(style.totalPadding.left, 0)
        XCTAssertEqual(node.bounds, CGRect(x: 42, y: 554, width: 996, height: 323))
        XCTAssertEqual(InspectorSnapshotIndex(snapshot, hidingInternals: true).byID[node.id]?.style, style)
    }
    func testMergedDescendantShapeCannotAssignStyleToParent() throws {
        XCTAssertNil(try snapshot(group: "mergedSemantics").nodes.last?.style)
    }
    func testDifferentRadiusCannotResolveAmbiguity() throws {
        XCTAssertNil(try snapshot(radius: 24).nodes.last?.style)
    }
    func testMatchingShapeWithConflictingColorsRemainsAmbiguous() throws {
        XCTAssertNil(try snapshot(conflicting: true).nodes.last?.style)
    }
    func testCircleUsesMeasuredHalfMinimumDimension() throws {
        XCTAssertEqual(try snapshot(shape: "CircleShape", radius: 161.5).nodes.last?.style?.layers.first?.shape?.topLeft, 161.5)
        XCTAssertNil(try snapshot(shape: "CircleShape", radius: 42).nodes.last?.style)
    }
    func testPercentageAndPixelInputsForCommonShapes() throws {
        for name in ["RoundedCornerShape", "AbsoluteRoundedCornerShape", "CutCornerShape", "AbsoluteCutCornerShape"] {
            for (unit, value, radius) in [("%", 25.0, 80.75), ("px", 12.0, 12.0), ("DP", 16.0, 42.0)] {
                for stringValue in [false, true] where !stringValue || unit != "DP" {
                    let style = try XCTUnwrap(try snapshot(shape: name, radius: radius, unit: unit, value: value, stringValue: stringValue).nodes.last?.style)
                    let shape = try XCTUnwrap(style.layers.first?.shape)
                    XCTAssertEqual(shape.topLeft, radius)
                    XCTAssertEqual(shape.kind, name.contains("Cut") ? "cut" : "rounded")
                    XCTAssertEqual(shape.corners?["topLeft"]?.value, value)
                    let restored = try JSONDecoder().decode(ComponentStyle.self, from: JSONEncoder().encode(style))
                    XCTAssertEqual(restored, style)
                }
            }
        }
    }
    func testPercentNormalizationAndInvalidPercentage() throws {
        XCTAssertNotNil(try snapshot(radius: 161.5, unit: "%", value: 80).nodes.last?.style)
        XCTAssertNil(try snapshot(radius: 161.5, unit: "%", value: 101).nodes.last?.style)
        XCTAssertNil(try snapshot(radius: 42, unit: "unknown").nodes.last?.style)
    }
    func testCircleAndCapsuleUseShapeLayerBounds() {
        let shape = ComponentStyle.Shape(name: "RoundedCornerShape", kind: "rounded", topLeft: 28, topRight: 28, bottomLeft: 28, bottomRight: 28)
        XCTAssertEqual(shape.title(in: CGRect(x: 0, y: 0, width: 56, height: 56)), "圆形")
        XCTAssertEqual(shape.title(in: CGRect(x: 0, y: 0, width: 120, height: 56)), "胶囊形")
        XCTAssertEqual(shape.title(in: CGRect(x: 0, y: 0, width: 88, height: 88)), "圆角")
    }

}
