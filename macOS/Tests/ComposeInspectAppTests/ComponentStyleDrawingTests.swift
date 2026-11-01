import XCTest
import SwiftUI
@testable import ComposeInspectApp
@testable import ComposeInspectCore

final class ComponentStyleDrawingTests: XCTestCase {
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
}
