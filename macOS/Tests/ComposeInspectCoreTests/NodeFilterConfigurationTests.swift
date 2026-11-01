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

    func testEveryDefaultRuleCanBeEnabledAndDisabledWithoutDroppingChildrenOrRoot() {
        for rule in NodeFilterConfiguration.defaults.viewRules {
            let source = snapshot(rule.className)
            var configuration = NodeFilterConfiguration.defaults
            let index = configuration.viewRules.firstIndex { $0.id == rule.id }!
            configuration.viewRules[index].enabled = true
            let compact = InspectorSnapshotIndex(source, hidingInternals: true, configuration: configuration)
            XCTAssertEqual(compact.nodes.map(\.id), ["root", "content"], rule.className)
            XCTAssertEqual(compact.parentIDs["content"], "root")
            configuration.viewRules[index].enabled = false
            XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true, configuration: configuration).nodes.map(\.id),
                           ["root", "wrapper", "content"], rule.className)
            XCTAssertEqual(source.nodes.map(\.id), ["root", "wrapper", "content"])
        }
    }

    func testCustomRulesValidateDeduplicateAndRoundTrip() throws {
        var configuration = NodeFilterConfiguration.defaults
        XCTAssertTrue(configuration.addViewRule("  example.CustomLayout  "))
        XCTAssertTrue(configuration.addViewRule("CustomLayout$Inner"))
        let count = configuration.viewRules.count
        configuration.viewRules[configuration.viewRules.count - 1].enabled = false
        XCTAssertTrue(configuration.addViewRule("CustomLayout$Inner"))
        XCTAssertEqual(configuration.viewRules.count, count)
        XCTAssertTrue(configuration.viewRules.last!.enabled)
        for invalid in ["", " ", "example..Layout", ".Layout", "View*", "123Layout", "a b", "Layout."] {
            XCTAssertFalse(configuration.addViewRule(invalid), invalid)
        }
        XCTAssertEqual(configuration.viewRules.count, count)
        XCTAssertEqual(try JSONDecoder().decode(NodeFilterConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("example.CustomLayout"), hidingInternals: true, configuration: configuration).nodes.map(\.id),
                       ["root", "content"])
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("example.CustomLayout"), configuration: configuration).nodes.count, 3)
    }

    func testQualifiedRuleDoesNotHideBusinessNamesAndOnlyTargetsAndroidViews() {
        let configuration = NodeFilterConfiguration.defaults
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("example.FrameLayout"), hidingInternals: true).nodes.count, 3)
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("FrameLayout"), hidingInternals: true).nodes.count, 2)
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("android.widget.FrameLayout", kind: "ComposeNode"), hidingInternals: true).nodes.count, 3)
        var custom = configuration
        XCTAssertTrue(custom.addViewRule("FrameLayout"))
        XCTAssertEqual(InspectorSnapshotIndex(snapshot("example.FrameLayout"), hidingInternals: true, configuration: custom).nodes.count, 2)
    }

    func testComposeRulesCanAllBeDisabledAndClickableRestrictionStillApplies() {
        let content = InspectorNode(id: "content", rawID: 4, name: "Content", bounds: bounds)
        let layout = InspectorNode(id: "layout", rawID: 3, name: "ReusableComposeNode", bounds: bounds, children: [content])
        let basic = InspectorNode(id: "basic", rawID: 2, name: "BasicText", bounds: bounds, children: [layout])
        let text = InspectorNode(id: "text", rawID: 1, name: "Text", bounds: bounds, children: [basic])
        let source = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: bounds.size, roots: [text])
        XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true).nodes.map(\.id), ["text", "content"])
        let configuration = NodeFilterConfiguration(hideTextImplementation: false, hideLayoutImplementation: false,
                                                    hideCompositionWrappers: false, viewRules: [])
        XCTAssertEqual(InspectorSnapshotIndex(source, hidingInternals: true, configuration: configuration).nodes.map(\.id), source.nodes.map(\.id))
        XCTAssertEqual(InspectorSnapshotIndex(source, onlyClickable: true, configuration: configuration).nodes.map(\.id), ["text"])
    }
}
