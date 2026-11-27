import XCTest
@testable import ComposeInspectCore

final class ImagePickingTests: XCTestCase {
    func testAreaComesBeforeDepthAndEqualAreaUsesDeeperThenTreeOrder() {
        let deepLarge = InspectorNode(id: "deep-large", rawID: 3, name: "Large", bounds: CGRect(x: 0, y: 0, width: 80, height: 80))
        let branch = InspectorNode(id: "branch", rawID: 2, name: "Branch", bounds: CGRect(x: 0, y: 0, width: 90, height: 90), children: [deepLarge])
        let child = InspectorNode(id: "equal-child", rawID: 6, name: "EqualChild", bounds: CGRect(x: 0, y: 0, width: 20, height: 20))
        let small = InspectorNode(id: "small", rawID: 4, name: "Small", bounds: CGRect(x: 0, y: 0, width: 20, height: 20), children: [child])
        let sibling = InspectorNode(id: "equal-sibling", rawID: 5, name: "EqualSibling", bounds: small.bounds)
        let empty = InspectorNode(id: "empty", rawID: 7, name: "Empty", bounds: .zero)
        let root = InspectorNode(id: "root", rawID: 1, name: "Root", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), children: [branch, small, sibling, empty])
        let other = InspectorNode(id: "other", rawID: 8, name: "OtherWindow", bounds: child.bounds)
        let snapshot = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: CGSize(width: 100, height: 100), roots: [root, other])
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: CGSize(width: 300, height: 250), zoom: 0.85)
        let point = mapper.display(CGRect(x: 10, y: 10, width: 0, height: 0)).origin
        let hits = mapper.candidates(at: point, in: InspectorSnapshotIndex(snapshot), imageSize: snapshot.pixelSize, rootID: root.id)
        XCTAssertEqual(hits.map(\.id), ["equal-child", "small", "equal-sibling", "deep-large", "branch", "root"])
        XCTAssertEqual(mapper.candidates(at: point, in: snapshot).map(\.id),
                       ["equal-child", "small", "equal-sibling", "other", "deep-large", "branch", "root"])
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: -1, y: -1), in: snapshot).isEmpty)
    }

    func testTallImageIsPickedBeforeItsLazyViewportOnlyInsideVisiblePortion() {
        let image = InspectorNode(id: "image", rawID: 60, name: "AsyncImage",
            bounds: CGRect(x: 84, y: 276, width: 1200, height: 1365))
        let list = InspectorNode(id: "list", rawID: 244, name: "LazyColumn",
            bounds: CGRect(x: 32, y: 128, width: 1304, height: 920), children: [image])
        let size = CGSize(width: 1920, height: 1080)
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: size, roots: [list])
        let mapper = CoordinateMapper(imageSize: size, canvasSize: size)
        XCTAssertEqual(mapper.candidates(at: CGPoint(x: 600, y: 500), in: snapshot).map(\.id), ["image", "list"])
        XCTAssertEqual(mapper.candidates(at: CGPoint(x: 600, y: 200), in: snapshot).map(\.id), ["list"])
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: 600, y: 1060), in: snapshot).isEmpty)
    }

    func testRepeatedClickBubblesThroughEveryCandidateAndWraps() {
        let hits = ["text", "button", "column", "window"]
        var cycle = ImageHitCycle()
        XCTAssertEqual(cycle.next(in: hits, selected: nil, at: .zero), "text")
        XCTAssertEqual(cycle.next(in: hits, selected: "text", at: CGPoint(x: 1, y: 1)), "button")
        XCTAssertEqual(cycle.next(in: hits, selected: "button", at: CGPoint(x: 10, y: 10)), "text")
        cycle.reset()
        var selected: String? = "column" // A tree selection must not change the first image hit.
        var actual: [String] = []
        for _ in 0..<6 {
            selected = cycle.next(in: hits, selected: selected)
            actual.append(selected!)
        }
        XCTAssertEqual(actual, ["text", "button", "column", "window", "text", "button"])
        XCTAssertEqual(cycle.next(in: ["icon", "window"], selected: selected), "icon")
        XCTAssertNil(cycle.next(in: [], selected: "icon"))
        XCTAssertEqual(cycle.next(in: hits, selected: "column"), "text")
        cycle.reset()
        XCTAssertEqual(cycle.next(in: hits, selected: "column"), "text")
        XCTAssertEqual(cycle.next(in: ["only"], selected: "text"), "only")
        XCTAssertEqual(cycle.next(in: ["only"], selected: "only"), "only")
    }
}
