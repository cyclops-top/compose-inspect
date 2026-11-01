import XCTest
@testable import ComposeInspectCore

final class LocatorContextTests: XCTestCase {
    func testSharedTextCallsiteKeepsBusinessCallersAndOmitsImplementationWrappers() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        func branch(_ id: String, line: Int) -> InspectorNode {
            let text = InspectorNode(id: id, rawID: 4, name: "Text", label: "关于", bounds: bounds,
                                     source: SourceAnchor(file: "GlassComponents.kt", line: 106))
            let row = InspectorNode(id: id + "row", rawID: 3, name: "Row", bounds: bounds,
                                    source: SourceAnchor(file: "GlassComponents.kt", line: 104), children: [text])
            return InspectorNode(id: id + "caller", rawID: 2, name: "SettingsRow", bounds: bounds,
                                 source: SourceAnchor(file: "SettingsScreens.kt", line: line), children: [row])
        }
        let screen = InspectorNode(id: "screen", rawID: 1, name: "SettingsScreen", bounds: bounds,
                                   source: SourceAnchor(file: "ReaderApp.kt", line: 96), children: [branch("first", line: 47), branch("second", line: 75)])
        let snapshot = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: bounds.size, roots: [screen])
        func prompt(_ id: String) -> String {
            LocatorTextBuilder.text(for: ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: id),
                                                       description: "文字改为应用信息", parameterIDs: []), in: snapshot)!
        }
        let first = prompt("first"), second = prompt("second")
        XCTAssertTrue(first.contains("ReaderApp.kt:96 · SettingsScreen\n  → SettingsScreens.kt:47 · SettingsRow\n  → GlassComponents.kt:106 · Text「关于」"))
        XCTAssertTrue(second.contains("SettingsScreens.kt:75 · SettingsRow"))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("GlassComponents.kt:104"))
        XCTAssertTrue(first.hasPrefix("请按以下要求修改：\n组件路径（采集，省略包装）："))
        XCTAssertTrue(first.hasSuffix("修改要求：\n文字改为应用信息"))
    }
}
