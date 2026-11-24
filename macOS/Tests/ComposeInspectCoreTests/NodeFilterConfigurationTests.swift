import XCTest
@testable import ComposeInspectCore

final class NodeFilterConfigurationTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func snapshot(_ name: String, kind: String = "ViewNode") -> InspectorSnapshot {
        let content = InspectorNode(id: "content", rawID: 3, name: "Text", bounds: bounds)
        let wrapper = InspectorNode(id: "wrapper", rawID: 2, name: name, kind: kind, bounds: bounds, children: [content])
        let root = InspectorNode(id: "root", rawID: 1, name: name, kind: "ViewNode", bounds: bounds, children: [wrapper])
        return InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: bounds.size, roots: [root])
    }

    func testHostPreferenceDecodesSavedRulesAndRoundTrips() throws {
        let base: [String: Any] = ["hideTextImplementation": false, "hideLayoutImplementation": true,
                                   "hideCompositionWrappers": false]
        let source = snapshot("androidx.compose.ui.platform.AndroidComposeView")
        for name in ["AndroidComposeView", "androidx.compose.ui.platform.AndroidComposeView", "example.OtherView"] {
            for enabled in [false, true] {
                var saved = base
                saved["viewRules"] = [["className": name, "enabled": enabled]]
                let data = try JSONSerialization.data(withJSONObject: saved)
                let settings = try JSONDecoder().decode(NodeFilterConfiguration.self, from: data)
                let hidden = enabled && name != "example.OtherView"
                XCTAssertEqual(settings.hideComposeHosts, hidden)
                XCTAssertFalse(settings.hideTextImplementation)
                XCTAssertFalse(settings.hideCompositionWrappers)
                let index = InspectorSnapshotIndex(source, hidingInternals: true, configuration: settings)
                XCTAssertEqual(index.nodes.map(\.id), hidden ? ["root", "content"] : ["root", "wrapper", "content"])
                XCTAssertEqual(try JSONDecoder().decode(NodeFilterConfiguration.self, from: JSONEncoder().encode(settings)), settings)
            }
        }
    }

    func testComposeRulesCanAllBeDisabledAndClickableRestrictionStillApplies() {
        let content = InspectorNode(id: "content", rawID: 4, name: "Content", bounds: bounds)
        let layout = InspectorNode(id: "layout", rawID: 3, name: "ReusableComposeNode", bounds: bounds, children: [content])
        let basic = InspectorNode(id: "basic", rawID: 2, name: "BasicText", bounds: bounds, children: [layout])
        let text = InspectorNode(id: "text", rawID: 1, name: "Text", bounds: bounds, children: [basic])
        let source = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: bounds.size, roots: [text])
        XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true).nodes.map(\.id), ["text", "content"])
        let configuration = NodeFilterConfiguration(hideTextImplementation: false, hideLayoutImplementation: false,
                                                    hideCompositionWrappers: false, hideComposeHosts: false)
        XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true, configuration: configuration).nodes.map(\.id), source.nodes.map(\.id))
        XCTAssertEqual(InspectorSnapshotIndex(source, onlyClickable: true, configuration: configuration).nodes.map(\.id), ["text"])
    }
}
