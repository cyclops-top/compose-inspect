import XCTest
@testable import ComposeInspectCore

final class NodeFilterTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func node(_ id: String, _ name: String, file: String? = nil, kind: String = "ComposeNode", children: [InspectorNode] = []) -> InspectorNode {
        InspectorNode(id: id, rawID: 1, name: name, kind: kind, bounds: rect,
                      source: file.map { SourceAnchor(file: $0, line: 10) }, children: children)
    }
    private func snapshot(_ root: InspectorNode) -> InspectorSnapshot {
        InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: rect.size, roots: [root])
    }

    func testTextImplementationIsHiddenWithoutDroppingSlotContentOrOriginalData() throws {
        let slot = node("slot", "InlineBusinessContent", file: "Article.kt")
        let internalNode = node("reuse", "ReusableComposeNode", file: "Layout.kt", children: [slot])
        let layout = node("layout", "Layout", file: "BasicText.kt", children: [internalNode])
        let basic = node("basic", "BasicText", file: "Text.kt", children: [layout])
        let text = node("text", "Text", file: "Article.kt", children: [basic])
        let source = snapshot(node("window", "ComposeView", kind: "ViewNode", children: [text]))
        let before = try JSONEncoder().encode(source)
        let compact = InspectorSnapshotIndex(source, hidingInternals: true)
        XCTAssertEqual(compact.nodes.map(\.id), ["window", "text", "slot"])
        XCTAssertEqual(compact.path(to: "slot").map(\.id), ["window", "text", "slot"])
        XCTAssertEqual(compact.byID["text"]?.source, text.source)
        XCTAssertEqual(compact.byID["text"]?.bounds, text.bounds)
        XCTAssertEqual(try JSONDecoder().decode(InspectorSnapshot.self, from: before), source)
        XCTAssertEqual(InspectorSnapshotIndex(source).nodes.map(\.id), ["window", "text", "basic", "layout", "reuse", "slot"])
    }

    func testPublicBusinessAndUnknownNodesArePreservedAndWindowRootAlwaysRemains() {
        let custom = node("custom", "Layout", file: "Dashboard.kt")
        let basic = node("standalone", "BasicText", file: "Article.kt")
        let view = node("view", "Layout", file: "Box.kt", kind: "ViewNode")
        let unknown = node("unknown", "Layout", file: "Future.kt", kind: "FutureNode")
        let column = node("column", "Column", file: "Dashboard.kt", children: [custom, basic, view, unknown])
        let source = snapshot(node("root", "ReusableComposeNode", file: "Layout.kt", children: [column]))
        XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true).nodes.map(\.id), source.nodes.map(\.id))
    }

    func testImageCandidatesSkipTextInternalsAndFullModeRestoresThem() {
        let reuse = node("reuse", "ReusableComposeNode", file: "Layout.kt")
        let layout = node("layout", "Layout", file: "BasicText.kt", children: [reuse])
        let basic = node("basic", "BasicText", file: "Text.kt", children: [layout])
        let text = node("text", "Text", file: "Page.kt", children: [basic])
        let source = snapshot(node("window", "View", kind: "ViewNode", children: [text]))
        let mapper = CoordinateMapper(imageSize: rect.size, canvasSize: rect.size)
        let point = CGPoint(x: 50, y: 50)
        let compact = mapper.candidates(at: point, in: InspectorSnapshotIndex(source, hidingInternals: true), imageSize: rect.size)
        XCTAssertEqual(compact.map(\.id), ["text", "window"])
        XCTAssertEqual(mapper.candidates(at: point, in: source).first?.id, "reuse")
    }
    func testCompositionWrappersPromoteChildrenButKeepSemanticAndBusinessNodes() {
        let business = node("business", "EmptyBusinessCard", file: "Settings.kt")
        let title = node("title", "Text", file: "Settings.kt")
        let pinned = node("pinned", "LazyLayoutPinnableItem", file: "LazyListItemProvider.kt", children: [title, business])
        let item = node("item", "Item", file: "LazyLayoutItemContentFactory.kt", children: [pinned])
        let saved = node("saved", "SaveableStateProvider", file: "LazyLayoutItemContentFactory.kt", children: [item])
        let sameName = node("businessItem", "Item", file: "Settings.kt")
        let semantic = InspectorNode(id: "semantic", rawID: 2, name: "Item", bounds: rect,
            source: SourceAnchor(file: "LazyLayoutItemContentFactory.kt"),
            parameters: [NodeParameter(id: "tag", name: "testTag", value: "row", group: .semantics)])
        let source = snapshot(node("window", "View", kind: "ViewNode", children: [saved, sameName, semantic]))
        let compact = InspectorSnapshotIndex(source, hidingInternals: true)
        XCTAssertEqual(compact.nodes.map(\.id), ["window", "title", "business", "businessItem", "semantic"])
        XCTAssertEqual(compact.parentIDs["business"], "window")
        XCTAssertEqual(InspectorSnapshotIndex(source).path(to: "business").map(\.id), ["window", "saved", "item", "pinned", "business"])
        let hits = CoordinateMapper(imageSize: rect.size, canvasSize: rect.size)
            .candidates(at: CGPoint(x: 50, y: 50), in: compact, imageSize: rect.size)
        XCTAssertFalse(hits.contains { ["saved", "item", "pinned"].contains($0.id) })
        XCTAssertEqual(compact.matchingIDs("EmptyBusinessCard"), ["window", "business"])
        XCTAssertTrue(compact.matchingIDs("nothing-matches").isEmpty)
        XCTAssertEqual(compact.matchingIDs(""), Set(compact.byID.keys))
    }

    func testAndroidHostsPromoteChildrenAndPreserveWindowRoot() {
        let text = node("text", "Text")
        let host = node("host", "androidx.compose.ui.platform.ComposeView", kind: "ViewNode", children: [text])
        let frame = node("frame", "android.widget.FrameLayout", kind: "ViewNode", children: [host])
        let source = snapshot(node("root", "android.widget.FrameLayout", kind: "ViewNode", children: [frame]))
        let compact = InspectorSnapshotIndex(source, hidingInternals: true)
        XCTAssertEqual(compact.nodes.map(\.id), ["root", "text"])
        XCTAssertEqual(compact.parentIDs["text"], "root")
        XCTAssertEqual(source.nodes.map(\.id), ["root", "frame", "host", "text"])
    }

    func testClickableProjectionKeepsRootsAndNestedActionsWithoutPruning() {
        func action(_ id: String, children: [InspectorNode] = []) -> InspectorNode {
            InspectorNode(id: id, rawID: 1, name: "Button", bounds: rect,
                parameters: [NodeParameter(id: id + "/click", name: "OnClick", value: "（参数组）", group: .unmergedSemantics)],
                children: children)
        }
        let nested = action("nested")
        let wrapper = node("layout", "Column", children: [nested])
        let button = action("button", children: [node("label", "Text"), wrapper])
        let view = InspectorNode(id: "view", rawID: 2, name: "android.widget.ImageView", kind: "ViewNode", bounds: rect,
            parameters: [NodeParameter(id: "clickable", name: "clickable", value: "true", group: .attribute)])
        let source = snapshot(node("root", "View", kind: "ViewNode", children: [button, view, node("plain", "Text")]))
        let result = InspectorSnapshotIndex(source, onlyClickable: true)
        XCTAssertEqual(result.nodes.map(\.id), ["root", "button", "nested", "view"])
        XCTAssertEqual(result.path(to: "nested").map(\.id), ["root", "button", "nested"])
        let hits = CoordinateMapper(imageSize: rect.size, canvasSize: rect.size)
            .candidates(at: CGPoint(x: 50, y: 50), in: result, imageSize: rect.size)
        XCTAssertEqual(Set(hits.map(\.id)), Set(result.nodes.map(\.id)))
        XCTAssertEqual(result.boundsByRoot["root"], [rect])
        XCTAssertNotNil(InspectorSnapshotIndex(source).byID["plain"])
    }

    func testClickableDetectionIgnoresCallbacksLongClickAndMergedDescendantActions() {
        let parameters = [
            NodeParameter(id: "callback", name: "onClick", value: "lambda", group: .parameter),
            NodeParameter(id: "long", name: "OnLongClick", value: "action", group: .unmergedSemantics),
            NodeParameter(id: "merged", name: "OnClick", value: "action", group: .mergedSemantics)
        ]
        let node = InspectorNode(id: "node", rawID: 1, name: "Button", bounds: rect, parameters: parameters)
        XCTAssertFalse(node.isClickable)
        let source = snapshot(self.node("root", "View", kind: "ViewNode", children: [node]))
        XCTAssertEqual(InspectorSnapshotIndex(source, onlyClickable: true).nodes.map(\.id), ["root"])
    }

}
