import XCTest
import SwiftUI
@testable import ComposeInspectCore
@testable import ComposeInspectApp

final class LazyItemPreviewTests: XCTestCase {
    func testTreeAndScenePromoteChildrenOfFilteredProviders() throws {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let content = InspectorNode(id: "content", rawID: 3, name: "QuestionCard", bounds: screen.insetBy(dx: 4, dy: 4))
        let provider = InspectorNode(id: "provider", rawID: 2, name: "CompositionLocalProvider", bounds: screen, children: [content])
        let root = InspectorNode(id: "root", rawID: 1, name: "Window", bounds: screen, children: [provider])
        let tree = try XCTUnwrap(ComposeNodeFilter.roots([root]).first)
        XCTAssertEqual(tree.children.map(\.id), [content.id])
        let snapshot = InspectorSnapshot(packageName: "sample", deviceName: "test", pixelSize: screen.size, roots: [root])
        let preview = PagePreviewGroup.projected(tree, original: InspectorSnapshotIndex(snapshot))
        let layers = PageSceneLayer.layout(preview, screen: screen, structuralOnly: true)
        XCTAssertFalse(layers.contains { $0.id == provider.id })
        XCTAssertTrue(layers.contains { $0.id == content.id })
        XCTAssertEqual(layers.last?.depth, 1)
    }

    func testOverlappingSolidsSeparateWhileDisjointCardsStayAligned() {
        func layer(_ id: String, x: CGFloat, depth: Int) -> PageSceneLayer {
            let box = CGRect(x: x, y: 0, width: 20, height: 20)
            return PageSceneLayer(id: id, face: Path(box), box: box, depth: depth)
        }
        let layers = [layer("first", x: 0, depth: 1), layer("overlap", x: 4, depth: 1),
                      layer("separate", x: 60, depth: 1), layer("next", x: 0, depth: 2)]
        let z = PageSceneLayer.frontPositions(layers)
        XCTAssertGreaterThan(z[1] - z[0], PageSceneLayer.thickness)
        XCTAssertEqual(z[0], z[2])
        XCTAssertGreaterThan(z[3] - z[1], PageSceneLayer.thickness)
    }

    func testEdgeAdjacentRowAndColumnItemsShareFrontPosition() {
        for step in [CGPoint(x: 19.5, y: 0), CGPoint(x: 0, y: 19.5)] {
            let layers = (0..<3).map { index in
                let box = CGRect(x: CGFloat(index) * step.x, y: CGFloat(index) * step.y,
                                 width: 19.5, height: 19.5)
                return PageSceneLayer(id: String(index), face: Path(box), box: box.integral, depth: 1)
            }
            XCTAssertEqual(Set(PageSceneLayer.frontPositions(layers)).count, 1)
        }
    }

    func testOffscreenSubtreeDoesNotCreateFullscreenSurfaces() {
        let screen = CGRect(x: 0, y: 0, width: 120, height: 100)
        let outside = CGRect(x: 125, y: 40, width: 40, height: 20)
        let text = InspectorNode(id: "text", rawID: 1, name: "Text", bounds: outside)
        let empty = InspectorNode(id: "empty", rawID: 2, name: "Layout", bounds: .zero)
        let bottom = InspectorNode(id: "bottom", rawID: 3, name: "Box",
                                   bounds: CGRect(x: 10, y: 95, width: 40, height: 20))
        let root = InspectorNode(id: "window", rawID: 0, name: "Window", bounds: screen, children: [text, empty, bottom])
        let layers = PageSceneLayer.layout(PagePreviewGroup(root), screen: screen, structuralOnly: true)
        XCTAssertEqual(layers.map(\.id), ["window", "bottom"])
        XCTAssertEqual(layers.last?.box, screen.intersection(bottom.bounds))
    }

    func testSubcompositionCardsOwnPixelsInFrontOfBackgroundAndThroughLayoutOnlyHost() throws {
        let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
        func node(_ name: String, _ identity: Int, _ bounds: CGRect) -> InspectorNode {
            InspectorNode(id: String(identity), rawID: Int64(identity), name: name, bounds: bounds,
                          clickTargetID: "sdk:\(identity)")
        }
        let background = node("Image", 1, screen)
        let cards = [node("Image", 2, CGRect(x: 20, y: 20, width: 40, height: 40)),
                     node("Image", 3, CGRect(x: 80, y: 20, width: 40, height: 40))]
        let overlay = node("SubcomposeLayout", 4, screen)
        let root = InspectorNode(id: "/windows/0/root", rawID: 0, name: "window", bounds: screen,
                                 children: [overlay] + cards + [background])
        let document = try InspectorDocument(data: Data(#"""
            {"windows":[{"sdkWindow":{"captureIndex":0}}],"sdkCapture":{"windows":[{"styleCatalogs":[{
              "records":[{"layoutIdentity":1},{"layoutIdentity":2},{"layoutIdentity":3},
                         {"layoutIdentity":4,"layers":[{"kind":"clip"}]}]
            }]}]}}
            """#.utf8))
        let order = PageSceneLayer.layoutOrder(root: root, document: document)
        let layers = PageSceneLayer.layout(PagePreviewGroup(root), screen: screen, structuralOnly: true, order: order)
        let z = PageSceneLayer.frontPositions(layers)
        let masks = PageSceneLayer.textureMasks(layers, positions: z)
        for node in cards + [background] {
            let point = node.id == background.id ? CGPoint(x: 10, y: 10) : CGPoint(x: node.bounds.midX, y: node.bounds.midY)
            let owners = layers.indices.filter { i in
                layers[i].carriesTexture && layers[i].face.contains(point) &&
                    !masks[i].contains { layers[$0].face.contains(point) }
            }
            XCTAssertEqual(owners.map { layers[$0].id }, [node.id])
        }
        XCTAssertEqual(layers.first { $0.id == cards[0].id }?.depth, layers.first { $0.id == cards[1].id }?.depth)
    }

    func testIndependentTablesCannotBothDisplayTheSameScreenshotPixel() {
        let page = CGRect(x: 0, y: 0, width: 140, height: 100)
        let shapes = [Path(page), Path(page), Path(ellipseIn: page.insetBy(dx: 15, dy: 12))]
        let layers = shapes.enumerated().map { index, face in
            PageSceneLayer(id: String(index), face: face, box: face.boundingRect, depth: index == 2 ? 2 : 1)
        }
        let masks = PageSceneLayer.textureMasks(layers, positions: PageSceneLayer.frontPositions(layers))
        for point in [CGPoint(x: 70, y: 50), CGPoint(x: 16, y: 13), CGPoint(x: 2, y: 2)] {
            let owners = layers.indices.filter { index in
                layers[index].face.contains(point) && !masks[index].contains { layers[$0].face.contains(point) }
            }
            XCTAssertEqual(owners, [shapes[2].contains(point) ? 2 : 1])
        }
    }

    func testDetachedItemsClearEnclosingPanelsAndInheritViewportClip() throws {
        let screen = CGRect(x: 0, y: 0, width: 120, height: 120)
        let viewport = screen.insetBy(dx: 10, dy: 10)
        func node(_ name: String, _ box: CGRect, _ children: [InspectorNode] = [], kind: String = "ComposeNode") -> InspectorNode {
            InspectorNode(id: name, rawID: 0, name: name, kind: kind, bounds: box, children: children)
        }
        let card = CGRect(x: 5, y: 20, width: 30, height: 40)
        let item = node("itemHost", card, [node("SkippableItem", card, [node("LazyLayoutPinnableItem", card)])], kind: "ViewNode")
        let overlay = node("floating", CGRect(x: 15, y: 25, width: 15, height: 20))
        let separate = node("separate", CGRect(x: 112, y: 2, width: 6, height: 6))
        let stack = node("Box", screen, [node("LazyLayout", viewport), overlay, separate])
        let root = node("window", screen, [item, stack, node("panel", screen)])
        let layers = PageSceneLayer.layout(PagePreviewGroup(root), screen: screen, structuralOnly: true)
        let index = try XCTUnwrap(layers.firstIndex { $0.id == "itemHost" })
        let floating = try XCTUnwrap(layers.firstIndex { $0.id == overlay.id })
        XCTAssertGreaterThan(layers[floating].depth, layers[index].depth)
        XCTAssertTrue(layers[index].coveringLayers.contains(floating))
        XCTAssertLessThan(try XCTUnwrap(layers.first { $0.id == separate.id }).depth, layers[floating].depth)
        XCTAssertEqual(layers[index].box, viewport.intersection(card))
        for container in layers where ["LazyLayout", "panel"].contains(container.id) {
            XCTAssertGreaterThan(layers[index].depth, container.depth)
            XCTAssertTrue(container.coveringLayers.contains(index))
        }
    }
}
