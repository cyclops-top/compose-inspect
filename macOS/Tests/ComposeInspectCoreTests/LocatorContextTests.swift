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
        XCTAssertTrue(first.contains("ReaderApp.kt:96 (SettingsScreen)\n  → SettingsScreens.kt:47 (SettingsRow)\n  → GlassComponents.kt:106 (Text「关于」)"))
        XCTAssertTrue(second.contains("SettingsScreens.kt:75 (SettingsRow)"))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("GlassComponents.kt:104"))
        XCTAssertTrue(first.hasPrefix("## 组件路径\n已省略包装组件，末项为目标。\n\n```text"))
        XCTAssertTrue(first.hasSuffix("## 修改要求\n文字改为应用信息"))
    }
    func testInvalidSourceDoesNotBecomeAnExactLocation() throws {
        let child = InspectorNode(id: "child", rawID: 2, name: "Text", label: "Find me", bounds: .zero,
            source: SourceAnchor(file: "  ", line: -1), idResource: "app:id/title", layoutResource: "app:layout/main")
        let root = InspectorNode(id: "root", rawID: 1, name: "Screen", bounds: .zero,
            source: SourceAnchor(file: "Screen.kt", line: 25), children: [child])
        let snapshot = InspectorSnapshot(packageName: "test.app", deviceName: "test", pixelSize: .zero, roots: [root])
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: "child"), description: "", parameterIDs: [])
        let text = try XCTUnwrap(LocatorTextBuilder.text(for: issue, in: snapshot))
        XCTAssertTrue(text.hasPrefix("## 组件路径\n已省略包装组件，末项为目标。\n\n```text"))
        XCTAssertTrue(text.contains("祖先定位线索：Screen.kt:25 · Screen（非当前组件位置）"))
        XCTAssertTrue(text.contains("资源 ID：app:id/title"))
        XCTAssertTrue(text.contains("布局资源：app:layout/main"))
        XCTAssertFalse(text.contains("## 修改要求"))
        XCTAssertFalse(text.contains(":-1"))
        XCTAssertEqual(LocatorTextBuilder.usableSource(SourceAnchor(file: "Main.kt", line: 0)), SourceAnchor(file: "Main.kt"))
    }

    func testMissingSourceAndUnknownLineRemainExplicit() {
        let noSource = InspectorNode(id: "none", rawID: 1, name: "View", bounds: .zero)
        let fileOnly = InspectorNode(id: "file", rawID: 2, name: "Text", bounds: .zero, source: SourceAnchor(file: "Main.kt", line: -1))
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: .zero, roots: [noSource, fileOnly])
        let index = InspectorSnapshotIndex(snapshot)
        XCTAssertTrue(LocatorTextBuilder.sourceSummary(for: "none", index: index).hasPrefix("无源码位置"))
        XCTAssertEqual(LocatorTextBuilder.sourceSummary(for: "file", index: index), "自身采集位置：Main.kt（行号未知）")
    }

    func testIdenticalInstancesOmitSnapshotMetadata() throws {
        let roots = ["first", "second"].map {
            InspectorNode(id: $0, rawID: 1, name: "Text", label: "同名", bounds: .zero,
                          source: SourceAnchor(file: "Shared.kt", line: 10))
        }
        let snapshot = InspectorSnapshot(packageName: "test", deviceName: "test", pixelSize: .zero, roots: roots)
        let texts = try roots.map { node in
            try XCTUnwrap(LocatorTextBuilder.text(for: ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: node.id),
                description: "", parameterIDs: []), in: snapshot))
        }
        XCTAssertEqual(texts[0], texts[1])
        for text in texts {
            XCTAssertFalse(text.contains("应用："))
            XCTAssertFalse(text.contains("同名同位置组件："))
            XCTAssertFalse(text.contains("窗口："))
            XCTAssertFalse(text.contains("本次快照节点路径"))
            XCTAssertTrue(text.contains("Shared.kt:10"))
        }
    }

}
