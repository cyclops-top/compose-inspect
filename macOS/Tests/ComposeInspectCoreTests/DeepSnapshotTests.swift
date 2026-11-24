import XCTest
@testable import ComposeInspectCore

final class DeepSnapshotTests: XCTestCase {
    func testDeepComposeTreeDecodesOnConcurrencyWorkerWithoutLosingPaths() async throws {
        let depth = 48
        var node = ""
        for index in (0..<depth).reversed() {
            let children = node.isEmpty ? "[]" : "[\(node)]"
            node = """
            {"id":\(index),"type":"ComposeNode","className":"Node\(index)","bounds":{"x":0,"y":0,"width":10,"height":10},"children":\(children)}
            """
        }
        let data = Data("{\"windows\":[{\"root\":\(node)}]}".utf8)
        let snapshot = try await Task.detached {
            try SnapshotImporter.decode(InspectorDocument(data: data), imageSize: CGSize(width: 10, height: 10), packageName: "test.app")
        }.value
        XCTAssertEqual(snapshot.nodes.count, depth)
        XCTAssertEqual(snapshot.nodes.map(\.rawID), (0..<depth).map(Int64.init))
        let leaf = try XCTUnwrap(snapshot.nodes.last)
        XCTAssertEqual(snapshot.path(to: leaf.id).count, depth)
        XCTAssertEqual(leaf.id, "/windows/0/root" + String(repeating: "/children/0", count: depth - 1))
        XCTAssertEqual(snapshot.document?.originalJSON, data)
    }
}
