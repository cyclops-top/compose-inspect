import XCTest
@testable import ComposeInspectCore

final class SnapshotIndexTests: XCTestCase {
    func testPickingTracksPannedAndZoomedImage() {
        let node = InspectorNode(id: "target", rawID: 1, name: "Text", bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: CGSize(width: 100, height: 100), roots: [node])
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: CGSize(width: 200, height: 200), zoom: 2, pan: CGSize(width: 50, height: -25))
        let point = CGPoint(x: 50, y: 35)
        XCTAssertEqual(mapper.imagePoint(point), CGPoint(x: 25, y: 40))
        XCTAssertEqual(mapper.candidates(at: point, in: snapshot).map(\.id), ["target"])
    }

    func testWireframesDeduplicateBoundsPerWindowWithoutRemovingPickCandidates() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let child = InspectorNode(id: "child", rawID: 2, name: "Text", bounds: rect)
        let root = InspectorNode(id: "root", rawID: 1, name: "Container", bounds: rect, children: [child])
        let other = InspectorNode(id: "other", rawID: 3, name: "Window", bounds: rect)
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: CGSize(width: 200, height: 200), roots: [root, other])
        let index = InspectorSnapshotIndex(snapshot)
        XCTAssertEqual(index.boundsByRoot["root"], [rect])
        XCTAssertEqual(index.boundsByRoot["other"], [rect])
        XCTAssertEqual(index.nodesByRoot["root"]?.count, 2)
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: snapshot.pixelSize)
        XCTAssertEqual(mapper.candidates(at: CGPoint(x: 20, y: 30), in: index, imageSize: snapshot.pixelSize, rootID: "root").map(\.id), ["child", "root"])
    }

    func testCachedLookupPathsAndBoundsMatchTreeAcrossWindows() {
        let demo = InspectorSnapshot.demo()
        let empty = InspectorNode(id: "other", rawID: 1, name: "OtherWindow", bounds: .zero)
        let snapshot = InspectorSnapshot(packageName: "example.app", deviceName: "test", pixelSize: demo.pixelSize,
                                         roots: demo.roots + [empty])
        let index = InspectorSnapshotIndex(snapshot)
        XCTAssertEqual(index.nodes.map(\.id), snapshot.nodes.map(\.id))
        for node in snapshot.nodes {
            XCTAssertEqual(index.byID[node.id], node)
            XCTAssertEqual(index.path(to: node.id).map(\.id), snapshot.path(to: node.id).map(\.id))
            XCTAssertEqual(index.rootIDs[node.id], snapshot.path(to: node.id).first?.id)
        }
        for root in snapshot.roots {
            XCTAssertEqual(index.nodesByRoot[root.id]?.map(\.id), root.flattened.map(\.id))
            let expected = root.flattened.map(\.bounds).filter { !$0.isEmpty }.reduce(into: [CGRect]()) { unique, rect in
                if !unique.contains(rect) { unique.append(rect) }
            }
            XCTAssertEqual(index.boundsByRoot[root.id] ?? [], expected)
        }
        XCTAssertNil(index.byID["missing"])
        XCTAssertTrue(index.path(to: "missing").isEmpty)
        XCTAssertNil(index.parentIDs[empty.id])
    }
}
