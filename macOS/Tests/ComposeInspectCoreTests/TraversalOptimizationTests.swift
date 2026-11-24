import XCTest
@testable import ComposeInspectCore

final class TraversalOptimizationTests: XCTestCase {
    private func snapshot(_ roots: [InspectorNode]) -> InspectorSnapshot {
        InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: CGSize(width: 100, height: 100), roots: roots)
    }

    func testDeepTraversalPreservesOrderAndSearchAncestors() throws {
        var node = InspectorNode(id: "leaf", rawID: 0, name: "Needle", bounds: .zero)
        for depth in (0..<1500).reversed() {
            node = InspectorNode(id: "n\(depth)", rawID: Int64(depth + 1), name: "Business", bounds: .zero, children: [node])
        }
        let source = snapshot([node])
        let index = InspectorSnapshotIndex(source, hidingInternals: true)
        XCTAssertEqual(index.nodes.map(\.id), source.nodes.map(\.id))
        XCTAssertEqual(index.depths["leaf"], 1500)
        XCTAssertEqual(index.matchingIDs("needle").count, 1501)
        XCTAssertEqual(index.path(to: "leaf").count, 1501)
    }

    func testCancellationInterruptsIndexAndFilterTraversal() {
        let source = InspectorSnapshot.demo()
        for filtered in [false, true] {
            var visits = 0
            XCTAssertThrowsError(try InspectorSnapshotIndex(source, hidingInternals: filtered, checkpoint: {
                visits += 1
                if visits == 4 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(visits, 4)
        }
    }
}
