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
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: -1, y: -1), in: snapshot).isEmpty)
    }

    func testRepeatedClickBubblesThroughEveryCandidateAndWraps() {
        let hits = ["text", "button", "column", "window"]
        var cycle = ImageHitCycle()
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
