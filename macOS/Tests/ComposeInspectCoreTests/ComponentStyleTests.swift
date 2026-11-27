import XCTest
@testable import ComposeInspectCore

final class ComponentStyleTests: XCTestCase {
    private func fixture(ambiguous: Bool = false) throws -> Data {
        let record: [String: Any] = ["contentBounds": ["x": 30, "y": 30, "width": 40, "height": 20],
            "outerBounds": ["x": 0, "y": 0, "width": 100, "height": 80],
            "layers": [
                ["name": "BackgroundElement", "kind": "background", "bounds": ["x": 0, "y": 0, "width": 100, "height": 80],
                 "argb": "80FF0000", "alpha": 0.5, "shape": ["kind": "unknown", "name": "example.WaveShape"]],
                ["name": "PaddingElement", "kind": "padding", "bounds": ["x": 0, "y": 0, "width": 100, "height": 80],
                 "padding": ["left": 5, "top": 5, "right": 5, "bottom": 5]],
                ["name": "BackgroundElement", "kind": "background", "bounds": ["x": 10, "y": 10, "width": 80, "height": 60],
                 "argb": "FFFFFFFF", "shape": ["kind": "rectangle", "name": "RectangleShape"]],
                ["name": "PaddingElement", "kind": "padding", "bounds": ["x": 10, "y": 10, "width": 80, "height": 60],
                 "padding": ["left": 10, "top": 10, "right": 10, "bottom": 10]],
                ["name": "GraphicsLayerElement", "kind": "graphicsLayer", "bounds": ["x": 30, "y": 30, "width": 40, "height": 20],
                 "graphicsParameters": [["name": "alpha", "value": "0.6"], ["name": "clip", "value": "false"]]],
                ["name": "ShadowGraphicsLayerElement", "kind": "shadow", "bounds": ["x": 30, "y": 30, "width": 40, "height": 20],
                 "shape": ["kind": "rectangle"], "shadow": ["elevationDp": 3.5, "clip": false,
                     "ambientColor": "80001122", "spotColor": "FF334455"]]]]
        var records = [record]
        if ambiguous {
            var duplicate = record
            duplicate["outerBounds"] = ["x": 20, "y": 20, "width": 60, "height": 40]
            records.append(duplicate)
        }
        let style: [String: Any] = ["version": 1, "density": 2, "records": records]
        let node: [String: Any] = ["id": -1, "type": "ComposeNode", "className": "Card",
            "bounds": ["x": 30, "y": 30, "width": 40, "height": 20]]
        let root: [String: Any] = ["id": 1, "type": "ViewNode", "className": "AndroidComposeView",
            "bounds": ["x": 0, "y": 0, "width": 200, "height": 200], "children": [node],
            "styleCatalog": style]
        return try JSONSerialization.data(withJSONObject: ["windows": [["root": root]]])
    }
    func testPaddingLayersBackgroundOrderUnknownShapeAndOuterHitAreaSurviveImportAndFiltering() throws {
        let data = try fixture()
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: data), imageSize: CGSize(width: 200, height: 200), packageName: "example")
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "Card" })
        let style = try XCTUnwrap(node.style)
        XCTAssertEqual(node.bounds, CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(style.contentBounds, CGRect(x: 30, y: 30, width: 40, height: 20))
        XCTAssertEqual(style.layers.map(\.kind), ["background", "padding", "background", "padding", "graphicsLayer", "shadow"])
        XCTAssertEqual(style.layers[4].graphicsParameters?.map(\.value), ["0.6", "false"])
        XCTAssertEqual(style.graphicsOpacity, 0.6)
        XCTAssertNil(style.layers[4].unsupported)
        let shadowLayer = try XCTUnwrap(style.layers.last)
        XCTAssertEqual(shadowLayer.shadow?.elevationDp, 3.5)
        XCTAssertEqual(shadowLayer.shadow?.clip, false)
        XCTAssertEqual(shadowLayer.shadow?.ambientColor, "80001122")
        XCTAssertEqual(shadowLayer.shadow?.spotColor, "FF334455")
        XCTAssertEqual(shadowLayer.shape?.kind, "rectangle")
        XCTAssertEqual(style.totalPadding.left, 15)
        XCTAssertEqual(style.layers[0].shape?.name, "example.WaveShape")
        XCTAssertEqual(style.layers[0].shape?.kind, "unknown")
        XCTAssertEqual(style.layers[0].argb, "80FF0000")
        XCTAssertEqual(style.layers[0].alpha, 0.5)
        let index = InspectorSnapshotIndex(snapshot, hidingInternals: true)
        XCTAssertEqual(index.byID[node.id]?.style, style)
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: snapshot.pixelSize)
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: 5, y: 5), in: index, imageSize: snapshot.pixelSize).contains { $0.id == node.id })
        XCTAssertEqual(snapshot.document?.originalJSON, data)
        let decoded = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.nodes.first { $0.id == node.id }?.style, style)
    }
    func testAmbiguousLayoutDoesNotBorrowAnOuterFrame() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: fixture(ambiguous: true)), imageSize: CGSize(width: 200, height: 200), packageName: "example")
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "Card" })
        XCTAssertNil(node.style)
        XCTAssertEqual(node.bounds, CGRect(x: 30, y: 30, width: 40, height: 20))
    }
    func testListCompositionEnvelopesFollowCorrectedChildOuterBoundsWithoutExpandingRealLayouts() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        var root = try XCTUnwrap(windows[0]["root"] as? [String: Any])
        let card = try XCTUnwrap((root["children"] as? [[String: Any]])?.first)
        let oldBox = ["x": 0, "y": 0, "width": 70, "height": 50]
        func wrapper(_ name: String, _ file: String, _ child: [String: Any], id: Int) -> [String: Any] {
            ["id": id, "type": "ComposeNode", "className": name, "bounds": oldBox,
             "sourceLocation": ["fileName": file, "lineNumber": 127], "children": [child]]
        }
        let pinned = wrapper("LazyLayoutPinnableItem", "LazyListItemProvider.kt", card, id: -2)
        let item = wrapper("Item", "LazyLayoutItemContentFactory.kt", pinned, id: -3)
        let saved = wrapper("SaveableStateProvider", "LazyLayoutItemContentFactory.kt", item, id: -4)
        // A real layout and a business function named Item must retain their measured bounds.
        let real = wrapper("Box", "CustomLayout.kt", saved, id: -5)
        let business = wrapper("Item", "Business.kt", card, id: -6)
        root["children"] = [real, business]
        windows[0]["root"] = root
        json["windows"] = windows
        let data = try JSONSerialization.data(withJSONObject: json)
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: data), imageSize: CGSize(width: 200, height: 200), packageName: "example")
        for name in ["LazyLayoutPinnableItem", "Item", "SaveableStateProvider"] {
            let node = try XCTUnwrap(snapshot.nodes.first { $0.name == name && $0.isVirtualLayoutGroup })
            XCTAssertEqual(node.bounds, CGRect(x: 0, y: 0, width: 100, height: 80))
            XCTAssertNil(node.style, "组合范围不能冒充子组件自身的样式")
        }
        XCTAssertEqual(snapshot.nodes.first { $0.name == "Box" }?.bounds, CGRect(x: 0, y: 0, width: 70, height: 50))
        XCTAssertEqual(snapshot.nodes.first { $0.source?.file == "Business.kt" }?.bounds, CGRect(x: 0, y: 0, width: 70, height: 50))
        XCTAssertEqual(snapshot.document?.originalJSON, data)
    }

    func testMeasuredDimensionsAreSelectableAndOnlyChosenSizesEnterAITargetText() throws {
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: fixture()), imageSize: CGSize(width: 200, height: 200), packageName: "example")
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "Card" })
        let width = try XCTUnwrap(node.layoutParameters.first { $0.name == "外框宽度" })
        XCTAssertEqual(width.value, "50dp")
        XCTAssertEqual(node.layoutParameters.first { $0.name == "内容区宽度" }?.value, "20dp")
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: node.id),
            description: "调整卡片", parameterIDs: [width.id])
        let text = try XCTUnwrap(LocatorTextBuilder.text(for: issue, in: snapshot))
        XCTAssertTrue(text.contains("外框宽度=50dp"))
        XCTAssertFalse(text.contains("外框高度="))
        XCTAssertFalse(text.contains("内容区宽度="))
        let unstyled = InspectorNode(id: "raw", rawID: 2, name: "Box", bounds: CGRect(x: 0, y: 0, width: 100, height: 20))
        XCTAssertEqual(unstyled.layoutParameters.first?.value, "100px")
        XCTAssertEqual(unstyled.layoutParameters.last?.value, "20px")
    }

    func testOutwardModifierLayersDriveSelectionWireframesAndPickingWithoutAddingPaddingTwice() throws {
        // SettingsRow reports 100dp, but places clip/click/padding 12dp outward on each side.
        // Density is 2, so the measured envelope is 248px, not a sum of padding layers.
        let content = ["x": 64, "y": 64, "width": 200, "height": 48]
        let outer = ["x": 64, "y": 40, "width": 200, "height": 96]
        let expanded = ["x": 40, "y": 40, "width": 248, "height": 96]
        let record: [String: Any] = ["contentBounds": content, "outerBounds": outer, "layers": [
            ["name": "GraphicsLayerElement", "kind": "clip", "bounds": expanded,
             "shape": ["name": "RectangleShape", "kind": "rectangle"]],
            ["name": "PaddingElement", "kind": "padding", "bounds": expanded,
             "padding": ["left": 12, "top": 0, "right": 12, "bottom": 0]],
            ["name": "PaddingElement", "kind": "padding", "bounds": outer,
             "padding": ["left": 0, "top": 12, "right": 0, "bottom": 12]]]]
        let styleJSON: [String: Any] = ["version": 1, "density": 2, "records": [record]]
        // An overflowing descendant must not inflate its real parent or this Row.
        let child: [String: Any] = ["id": -3, "type": "ComposeNode", "className": "Text",
            "bounds": ["x": 320, "y": 64, "width": 20, "height": 20]]
        let row: [String: Any] = ["id": -2, "type": "ComposeNode", "className": "Row", "bounds": content,
            "unmergedSemantics": [["name": "OnClick", "value": "[lambda]"]], "children": [child]]
        let parent: [String: Any] = ["id": -1, "type": "ComposeNode", "className": "Box", "bounds": outer, "children": [row]]
        let root: [String: Any] = ["id": 1, "type": "ViewNode", "className": "AndroidComposeView",
            "bounds": ["x": 0, "y": 0, "width": 400, "height": 300], "children": [parent],
            "styleCatalog": styleJSON]
        let data = try JSONSerialization.data(withJSONObject: ["windows": [["root": root]]])
        let snapshot = try SnapshotImporter.decode(InspectorDocument(data: data), imageSize: CGSize(width: 400, height: 300), packageName: "example")
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "Row" })
        let style = try XCTUnwrap(node.style)
        let expected = CGRect(x: 40, y: 40, width: 248, height: 96)
        XCTAssertEqual(style.outerBounds, CGRect(x: 64, y: 40, width: 200, height: 96))
        XCTAssertEqual(style.contentBounds, CGRect(x: 64, y: 64, width: 200, height: 48))
        XCTAssertEqual(style.selectionBounds, expected)
        XCTAssertEqual(node.bounds, expected)
        XCTAssertEqual(node.layoutParameters.first?.value, "124dp")
        XCTAssertEqual(snapshot.nodes.first { $0.name == "Box" }?.bounds, style.outerBounds)
        for index in [InspectorSnapshotIndex(snapshot), InspectorSnapshotIndex(snapshot, hidingInternals: true),
                      InspectorSnapshotIndex(snapshot, onlyClickable: true)] {
            XCTAssertEqual(index.byID[node.id]?.bounds, expected)
            XCTAssertTrue(index.boundsByRoot[snapshot.roots[0].id]?.contains(expected) == true)
            for mapper in [CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: snapshot.pixelSize),
                           CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: CGSize(width: 700, height: 600),
                                            zoom: 1.4, pan: CGSize(width: -15, height: 20))] {
                for imagePoint in [CGPoint(x: 41, y: 70), CGPoint(x: 287, y: 70)] {
                    let screen = mapper.display(CGRect(origin: imagePoint, size: .zero)).origin
                    XCTAssertEqual(mapper.candidates(at: screen, in: index, imageSize: snapshot.pixelSize).first?.id, node.id)
                }
                for imagePoint in [CGPoint(x: 39, y: 70), CGPoint(x: 289, y: 70), CGPoint(x: 325, y: 70)] {
                    let screen = mapper.display(CGRect(origin: imagePoint, size: .zero)).origin
                    XCTAssertFalse(mapper.candidates(at: screen, in: index, imageSize: snapshot.pixelSize).contains { $0.id == node.id })
                }
            }
        }
        XCTAssertEqual(snapshot.document?.originalJSON, data)
        let decoded = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.node(node.id)?.bounds, expected)
        XCTAssertEqual(decoded.node(node.id)?.style, style)
    }

    func testOffsetSelectionDoesNotIncludeOriginalLayoutAllocation() throws {
        for origin in [CGPoint(x: 686, y: 158), CGPoint(x: -200, y: -100), CGPoint(x: 20, y: 10)] {
            let content = CGRect(origin: origin, size: CGSize(width: 548, height: 384))
            let outer = CGRect(x: 0, y: 0, width: 548, height: 384)
            let style = ComponentStyle(density: 1, contentBounds: content, outerBounds: outer, layers: [])
            XCTAssertEqual(style.selectionBounds, content)
            let node = InspectorNode(id: "image", rawID: -1, name: "Image", bounds: style.selectionBounds, style: style)
            let snapshot = InspectorSnapshot(packageName: "example", deviceName: "test",
                pixelSize: CGSize(width: 1920, height: 1080), roots: [node])
            let index = InspectorSnapshotIndex(snapshot)
            XCTAssertEqual(index.boundsByRoot[node.id], [content])
            let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: snapshot.pixelSize)
            XCTAssertEqual(mapper.candidates(at: CGPoint(x: content.midX, y: content.midY),
                in: index, imageSize: snapshot.pixelSize).first?.id, node.id)
        }
    }

    func testEnvelopeIncludesMeasuredContentOverflowAndIgnoresEmptyLayers() {
        let outer = CGRect(x: 20, y: 30, width: 100, height: 50)
        let content = CGRect(x: 10, y: 10, width: 120, height: 90)
        let empty = ComponentStyle.Layer(id: 0, name: "PaddingElement", kind: "padding",
            bounds: CGRect(x: -500, y: -500, width: 0, height: 0), padding: nil, argb: nil,
            alpha: 1, shape: nil, unsupported: nil)
        let style = ComponentStyle(density: 2, contentBounds: content, outerBounds: outer, layers: [empty])
        XCTAssertEqual(style.selectionBounds, content)
    }

}
