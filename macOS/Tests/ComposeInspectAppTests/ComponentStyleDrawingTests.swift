import XCTest
import SwiftUI
import SceneKit
@testable import ComposeInspectApp
@testable import ComposeInspectCore

final class ComponentStyleDrawingTests: XCTestCase {
    func testCustomPathScalesToLayerAndKeepsEvenOddHole() {
        var shape = ComponentStyle.Shape(name: "Ring", kind: "path",
            topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)
        func contour(_ low: Double, _ high: Double) -> [ComponentStyle.Shape.Command] {
            [.init(verb: "Move", coordinates: [low, low]),
             .init(verb: "Line", coordinates: [high, low]),
             .init(verb: "Line", coordinates: [high, high]),
             .init(verb: "Line", coordinates: [low, high]),
             .init(verb: "Close", coordinates: [])]
        }
        shape.commands = contour(0, 1) + contour(0.25, 0.75)
        shape.evenOdd = true
        let box = CGRect(x: 12, y: 40, width: 120, height: 60)
        let path = ComponentStyleDrawing.path(in: box, shape: shape, scale: 3)
        XCTAssertEqual(path.boundingRect, box)
        XCTAssertTrue(path.contains(CGPoint(x: 16, y: 70)))
        XCTAssertFalse(path.contains(CGPoint(x: box.midX, y: box.midY)))
    }

    @MainActor
    func testPageZoomKeepsOffCenterSurfaceUnderPointer() throws {
        _ = NSApplication.shared
        let view = PageSceneView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let scene = SCNScene()
        view.scene = scene
        view.allowsCameraControl = true
        let box = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 0.1, chamferRadius: 0))
        box.position = SCNVector3(1, 0.6, 0)
        scene.rootNode.addChildNode(box)
        let eye = SCNNode()
        eye.camera = SCNCamera()
        eye.position = SCNVector3(2, 1, 9)
        eye.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(eye)
        view.pointOfView = eye
        view.defaultCameraController.target = SCNVector3Zero
        _ = view.snapshot()
        let pixel = view.projectPoint(SCNVector3(1.2, 0.75, 0.05))
        let pointer = CGPoint(x: pixel.x, y: pixel.y)
        let hit = try XCTUnwrap(view.hitTest(pointer, options: nil).first)
        let anchor = hit.worldCoordinates
        let distance = simd_distance(eye.simdWorldPosition, SIMD3<Float>(anchor))

        for factor: CGFloat in [2, 0.5] {
            view.zoom(at: pointer, by: factor)
            _ = view.snapshot()
            let projected = view.projectPoint(anchor)
            XCTAssertEqual(projected.x, pixel.x, accuracy: 0.5)
            XCTAssertEqual(projected.y, pixel.y, accuracy: 0.5)
            XCTAssertEqual(simd_distance(eye.simdWorldPosition, SIMD3<Float>(anchor)),
                           factor == 2 ? distance / 2 : distance, accuracy: 0.01)
        }
    }

    @MainActor
    func testPageSolidExtrudesMeasuredCornerAndPreservesTextureOrientation() throws {
        let box = CGRect(x: 30, y: 50, width: 100, height: 80)
        let shape = ComponentStyle.Shape(name: "RoundedCornerShape", kind: "rounded",
                                         topLeft: 36, topRight: 0, bottomLeft: 0, bottomRight: 0)
        let face = ComponentStyleDrawing.path(in: box, shape: shape, scale: 1)
        let front = SCNMaterial(), back = SCNMaterial(), side = SCNMaterial()
        let geometry = PageScene.solid(face: face, box: box, unit: 0.02, thickness: 0.065,
                                       front: front, side: side, back: back)
        let node = SCNNode(geometry: geometry)
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)
        view.scene = scene
        _ = view.snapshot()
        func hit(_ x: CGFloat, _ y: CGFloat) -> SCNHitTestResult? {
            node.hitTestWithSegment(from: SCNVector3(x, y, 1), to: SCNVector3(x, y, 0), options: nil).first
        }
        XCTAssertNil(hit(-0.96, 0.76))
        let topRight = try XCTUnwrap(hit(0.96, 0.76))
        XCTAssertTrue(geometry.materials[topRight.geometryIndex] === front)
        XCTAssertLessThan(topRight.textureCoordinates(withMappingChannel: 0).y, 0.1)
        XCTAssertNotNil(hit(-0.96, -0.76))
        let rim = try XCTUnwrap(node.hitTestWithSegment(from: SCNVector3(2, 0, 0),
                                                        to: SCNVector3Zero, options: nil).first)
        XCTAssertTrue(geometry.materials[rim.geometryIndex] === side)
    }

    func testLaterSiblingSitsAboveOverlappingDescendantsOnly() throws {
        func node(_ name: String, _ bounds: CGRect, children: [InspectorNode] = []) -> InspectorNode {
            InspectorNode(id: name, rawID: 0, name: name, bounds: bounds, children: children)
        }
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let room = node("room", CGRect(x: 0, y: 20, width: 60, height: 60))
        let content = node("content", screen.insetBy(dx: 2, dy: 2), children: [room])
        let marker = node("marker", CGRect(x: 40, y: 45, width: 25, height: 25))
        let separate = node("separate", CGRect(x: 75, y: 45, width: 10, height: 10))
        let root = node("root", screen, children: [content, marker, separate])
        let layers = PageSceneLayer.layout(PagePreviewGroup(root), screen: screen)
        let foreground = try XCTUnwrap(layers.firstIndex { $0.id == "marker" })
        let underneath = try XCTUnwrap(layers.first { $0.id == "room" })
        XCTAssertGreaterThan(layers[foreground].depth, underneath.depth)
        XCTAssertTrue(underneath.coveringLayers.contains(foreground))
        XCTAssertEqual(layers.last?.depth, underneath.depth)
    }

    func testPagePreviewCollapsesMatchingChainsAndPreservesBranchAndStyleChanges() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let styled = ComponentStyle(density: 1, contentBounds: box, outerBounds: box, layers: [])
        func node(_ name: String, _ children: [InspectorNode] = [], style: ComponentStyle? = nil,
                  bounds: CGRect? = nil) -> InspectorNode {
            InspectorNode(id: name, rawID: 0, name: name, bounds: bounds ?? box, children: children, style: style)
        }
        let tree = node("root", [node("wrapper", [node("left", [node("color", style: styled)]),
                                                    node("right", [node("inset", bounds: box.insetBy(dx: 5, dy: 5))])])])
        let group = PagePreviewGroup(tree)
        XCTAssertEqual(group.children.map(\.id), ["left", "right"])
        XCTAssertEqual(group.children.flatMap(\.children).map(\.id), ["inset"])
        let shadow = ComponentStyle.Layer(id: 0, name: "shadow", kind: "shadow", bounds: box,
            padding: nil, argb: nil, alpha: 1, shape: nil, unsupported: nil)
        let painted = ComponentStyle(density: 1, contentBounds: box, outerBounds: box, layers: [shadow])
        XCTAssertEqual(PagePreviewGroup(node("outer", [node("inner", style: painted)])).children.map(\.id), ["inner"])

        let measured = node("Column", [node("measure", bounds: .zero), node("Layout", [node("Reusable")])])
        let measuredGroup = PagePreviewGroup(measured)
        XCTAssertEqual(measuredGroup.children.map(\.id), ["measure"])

        let fork = node("root", [node("wrapper", [node("visible")], bounds: .zero), node("Layout")])
        XCTAssertEqual(PagePreviewGroup(fork).children.map(\.id), ["wrapper", "Layout"])
    }

    func testWireframesDeduplicateOnlyMatchingCornerGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        func outline(_ kind: String, topLeft: Double) -> ComponentWireframeOutline {
            let shape = ComponentStyle.Shape(name: kind, kind: kind, topLeft: topLeft, topRight: 0,
                                             bottomLeft: 4, bottomRight: 0)
            let layer = ComponentStyle.Layer(id: 0, name: "shape", kind: "clip", bounds: bounds,
                padding: nil, argb: nil, alpha: 1, shape: shape, unsupported: nil)
            let style = ComponentStyle(density: 1, contentBounds: bounds, outerBounds: bounds, layers: [layer])
            return ComponentWireframeOutline(InspectorNode(id: kind, rawID: 0, name: kind, bounds: bounds, style: style))
        }
        let outlines = [outline("rectangle", topLeft: 0), outline("rounded", topLeft: 10),
                        outline("cut", topLeft: 10), outline("cut", topLeft: 20), outline("cut", topLeft: 10)]
        XCTAssertEqual(Set(outlines).count, 4)
    }

    func testTransparentClipHasRoundedOutlineAtItsMeasuredBoundsAndScale() {
        let shape = ComponentStyle.Shape(name: "RoundedCornerShape", kind: "rounded",
            topLeft: 20, topRight: 10, bottomLeft: 0, bottomRight: 15)
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 80)
        let layer = ComponentStyle.Layer(id: 0, name: "GraphicsLayerElement", kind: "clip", bounds: bounds,
            padding: nil, argb: nil, alpha: 1, shape: shape, unsupported: nil)
        let style = ComponentStyle(density: 2, contentBounds: bounds, outerBounds: bounds, layers: [layer])
        let outline = ComponentStyleDrawing.outlineShape(style: style, bounds: bounds)
        XCTAssertEqual(outline, shape)
        let path = ComponentStyleDrawing.path(in: CGRect(x: 30, y: 40, width: 400, height: 160), shape: outline, scale: 2)
        XCTAssertFalse(path.contains(CGPoint(x: 31, y: 41)), "Rounded top-left must not remain rectangular")
        XCTAssertTrue(path.contains(CGPoint(x: 31, y: 199)), "Zero-radius bottom-left remains square")
        XCTAssertTrue(path.contains(CGPoint(x: 230, y: 120)))
        XCTAssertEqual(path.boundingRect, CGRect(x: 30, y: 40, width: 400, height: 160))
        XCTAssertNil(ComponentStyleDrawing.outlineShape(style: style, bounds: bounds.insetBy(dx: -10, dy: -10)),
                     "An inner clip must not round unrelated outer padding")
        let fallback = ComponentStyleDrawing.path(in: bounds, shape: nil, scale: 1)
        XCTAssertTrue(fallback.contains(CGPoint(x: 11, y: 21)))
    }
    func testExplodedPlanesRetainOffsetsAndPaddingHitRegions() {
        let b = CGRect(x: 300, y: 150, width: 180, height: 80)
        let padding = ComponentStyle.Layer(id: 0, name: "Padding", kind: "padding", bounds: b,
            padding: .init(left: 8, top: 4, right: 8, bottom: 4), argb: nil, alpha: 1, shape: nil, unsupported: nil)
        let background = ComponentStyle.Layer(id: 1, name: "Background", kind: "background", bounds: b,
            padding: nil, argb: "FF0022AA", alpha: 1, shape: nil, unsupported: nil)
        let style = ComponentStyle(density: 2, contentBounds: b, outerBounds: b, layers: [padding, background])
        let front = StylePlane(0, style: style, transform: .identity)
        XCTAssertTrue(front.contains(CGPoint(x: 315, y: 190)))
        XCTAssertFalse(front.surface.contains(CGPoint(x: b.midX, y: b.midY)))
        XCTAssertTrue(front.contains(CGPoint(x: b.midX, y: b.midY)))
        let layout = StyleStackLayout(style: style, size: CGSize(width: 430, height: 380))
        let inner = layout.plane(1).outline.boundingRect
        let outer = layout.plane(0).outline.boundingRect
        XCTAssertLessThan(inner.midY, outer.midY)
        XCTAssertEqual(inner.midX, outer.midX, accuracy: 0.01)
        XCTAssertEqual(layout.hit(CGPoint(x: inner.midX, y: inner.midY)), 1)
        XCTAssertEqual(layout.hit(CGPoint(x: outer.midX, y: outer.midY)), 0)
    }

    func testOnlyPrecedingExplicitClipsRestrictInnerPlanes() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 100)
        let cut = ComponentStyle.Shape(name: "CutCornerShape", kind: "cut",
                                      topLeft: 36, topRight: 0, bottomLeft: 0, bottomRight: 0)
        let rect = ComponentStyle.Shape(name: "RectangleShape", kind: "rectangle",
                                       topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)
        func layer(_ kind: String, _ shape: ComponentStyle.Shape? = nil, in box: CGRect? = nil) -> ComponentStyle.Layer {
            .init(id: 0, name: kind, kind: kind, bounds: box ?? bounds,
                  padding: kind == "padding" ? .init(left: 15, top: 15, right: 15, bottom: 15) : nil,
                  argb: "FFFFFFFF", alpha: 1, shape: shape, unsupported: nil)
        }
        let layers = [layer("background", cut), layer("background"), layer("clip", cut),
                      layer("padding"), layer("clip", rect, in: CGRect(x: 10, y: 20, width: 60, height: 100)),
                      layer("background")]
        let style = ComponentStyle(density: 1, contentBounds: bounds, outerBounds: bounds, layers: layers)
        func plane(_ index: Int) -> StylePlane { StylePlane(index, style: style, transform: .identity) }
        let corner = CGPoint(x: 14, y: 24)
        XCTAssertTrue(plane(1).contains(corner))
        XCTAssertFalse(plane(3).contains(corner))
        XCTAssertTrue(plane(3).surface.contains(CGPoint(x: 17, y: 75)))
        XCTAssertFalse(plane(3).surface.contains(CGPoint(x: 55, y: 70)))
        XCTAssertFalse(plane(5).contains(corner))
        XCTAssertFalse(plane(5).contains(CGPoint(x: 95, y: 70)))
        XCTAssertTrue(plane(5).contains(CGPoint(x: 50, y: 70)))
    }

    @MainActor
    func testStyleSheetRestoresResizedContentWhenReopened() throws {
        _ = NSApplication.shared
        let key = "StylePreviewContentSize"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.removeObject(forKey: key)

        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let layer = ComponentStyle.Layer(id: 0, name: "Background", kind: "background", bounds: bounds,
            padding: nil, argb: "FF0022AA", alpha: 1, shape: nil, unsupported: nil)
        let style = ComponentStyle(density: 1, contentBounds: bounds, outerBounds: bounds, layers: [layer, layer])
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let selection = StylePreviewSelection()
        let presenting = StylePreviewSheet(isPresented: .constant(true), onDismiss: {}) {
            ExplodedStylePreview(name: "Test", style: style, screenshot: nil, bounds: bounds, selection: selection, dismiss: {})
        }
        let hidden = StylePreviewSheet(isPresented: .constant(false), onDismiss: {}, content: presenting.content)
        let host = NSHostingView(rootView: hidden)
        parent.contentView = host
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

        // Attach the presenter before opening, as the inspector button does.
        settle()
        host.rootView = presenting
        settle()
        let panel = try XCTUnwrap(parent.attachedSheet)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        func arrow(_ scalar: Int, keyCode: UInt16) throws -> Bool {
            let key = String(UnicodeScalar(scalar)!)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
            return panel.performKeyEquivalent(with: event)
        }
        XCTAssertTrue(try arrow(NSUpArrowFunctionKey, keyCode: 126))
        XCTAssertEqual(selection.index, 1)
        XCTAssertTrue(try arrow(NSUpArrowFunctionKey, keyCode: 126))
        XCTAssertEqual(selection.index, 1)
        XCTAssertTrue(try arrow(NSDownArrowFunctionKey, keyCode: 125))
        XCTAssertEqual(selection.index, 0)
        let initial = try XCTUnwrap(panel.contentView?.bounds.size)
        let resized = CGSize(width: initial.width - 35, height: initial.height - 25)
        panel.setContentSize(resized)
        settle()
        host.rootView = hidden
        settle()
        host.rootView = presenting
        settle()
        let reopened = try XCTUnwrap(parent.attachedSheet)
        XCTAssertEqual(reopened.contentView?.bounds.size, resized)
        parent.endSheet(reopened)
    }

    @MainActor
    func testScreenshotCropIntersectsPhysicalImageBounds() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let crop = try XCTUnwrap(ExplodedStylePreview.crop(image, to: CGRect(x: -8, y: 4, width: 18, height: 20)))
        XCTAssertEqual(crop.width, 10)
        XCTAssertEqual(crop.height, 12)
        XCTAssertNil(ExplodedStylePreview.crop(image, to: CGRect(x: 21, y: 0, width: 20, height: 16)))
    }

}
