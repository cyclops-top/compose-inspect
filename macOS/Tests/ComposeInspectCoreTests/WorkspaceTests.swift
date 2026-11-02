import XCTest
import CoreGraphics
@testable import ComposeInspectCore

final class WorkspaceTests: XCTestCase {
    func testOnlyNonemptyDescriptionsBecomeIssues() {
        let snapshot = InspectorSnapshot.demo()
        let key = ComponentKey(snapshotID: snapshot.id, nodeID: "login")
        var ledger = IssueLedger()
        ledger.update(key, description: " \n\t", parameterIDs: ["修饰符.height"])
        XCTAssertTrue(ledger.issues.isEmpty)
        ledger.update(key, description: "高度改为 56dp", parameterIDs: ["修饰符.height"])
        XCTAssertEqual(ledger.issues.count, 1)
        let originalID = ledger.issues[0].id
        ledger.update(key, description: "高度改为 60dp", parameterIDs: [])
        XCTAssertEqual(ledger.issues.count, 1)
        XCTAssertEqual(ledger.issues[0].id, originalID)
        ledger.update(key, description: "", parameterIDs: [])
        XCTAssertTrue(ledger.issues.isEmpty)
    }

    func testComponentsKeepIndependentDescriptionsParametersAndOrder() {
        let snapshot = InspectorSnapshot.demo()
        let login = ComponentKey(snapshotID: snapshot.id, nodeID: "login")
        let email = ComponentKey(snapshotID: snapshot.id, nodeID: "email")
        var ledger = IssueLedger()
        ledger.update(login, description: "改高度", parameterIDs: ["修饰符.height"])
        ledger.update(email, description: "改字号", parameterIDs: ["组件参数.textStyle.fontSize"])
        ledger.update(login, description: "改为56dp", parameterIDs: [])
        XCTAssertEqual(ledger.issues.map(\.component), [login, email])
        XCTAssertEqual(ledger.issue(for: email)?.description, "改字号")
        XCTAssertEqual(ledger.issue(for: email)?.parameterIDs, ["组件参数.textStyle.fontSize"])
        XCTAssertTrue(ledger.issue(for: login)!.parameterIDs.isEmpty)
    }

    func testTextOnlyExportsSelectedParametersAndPreservesDescription() {
        let snapshot = InspectorSnapshot.demo()
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: "login"),
                                   description: "高度改成 56dp\n保持现有圆角", parameterIDs: ["修饰符.height"])
        let text = LocatorTextBuilder.text(for: issue, in: snapshot)!
        XCTAssertEqual(text, "请按以下要求修改：\n组件路径（采集，省略包装）：\nLoginScreen.kt:30 · LoginScreen\n  → LoginScreen.kt:86 · Button「登录」\n自身采集位置：LoginScreen.kt:86\n位置来自运行时采集，表示调用位置线索，不是已验证的函数声明；请结合项目代码确认。\nheight=48dp\n修改要求：\n高度改成 56dp\n保持现有圆角")
        XCTAssertFalse(text.contains("enabled"))
        XCTAssertFalse(text.contains("#42"))
        XCTAssertFalse(text.contains("login_submit"))
    }

    func testMissingSourceIsExplicitlyAnAncestorLocation() {
        let snapshot = InspectorSnapshot.demo()
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: "login-text"),
                                   description: "文字加粗", parameterIDs: [])
        let text = LocatorTextBuilder.text(for: issue, in: snapshot)!
        XCTAssertTrue(text.contains("位于 LoginScreen.kt:86 的 Button 内 · Text「登录」"))
    }

    func testBatchFailsInsteadOfSilentlySkippingUnavailableSources() {
        let snapshot = InspectorSnapshot.demo()
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: "login"), description: "修改", parameterIDs: [])
        XCTAssertNil(LocatorTextBuilder.batch([issue], snapshots: [:]))
        XCTAssertTrue(LocatorTextBuilder.batch([issue], snapshots: [snapshot.id: snapshot])!.hasPrefix("1. 请按以下要求修改："))
    }

    func testCoordinateMappingAndNestedHitCandidates() {
        let snapshot = InspectorSnapshot.demo()
        let mapper = CoordinateMapper(imageSize: snapshot.pixelSize, canvasSize: CGSize(width: 500, height: 470), zoom: 0.85)
        let bounds = snapshot.node("login-text")!.bounds
        let mapped = mapper.display(bounds)
        let original = mapper.imagePoint(CGPoint(x: mapped.midX, y: mapped.midY))
        XCTAssertEqual(original.x, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(original.y, bounds.midY, accuracy: 0.001)
        let hits = mapper.candidates(at: CGPoint(x: mapped.midX, y: mapped.midY), in: snapshot)
        XCTAssertEqual(hits.first?.id, "login-text")
        XCTAssertTrue(hits.contains { $0.id == "login" })
        XCTAssertTrue(mapper.candidates(at: CGPoint(x: -1, y: -1), in: snapshot).isEmpty)
    }

    func testImporterUsesCurrentSchemaAndPreservesInt64IDAndParameterUnits() throws {
        let data = Data(#"""
        {"displays":[{"id":0}],"windows":[{"root":{
          "type":"ViewNode","id":1,"className":"ComposeView","bounds":{"x":0,"y":0,"width":1080,"height":2220},
          "children":[{"type":"ComposeNode","id":9223372036854775806,"className":"Text",
          "bounds":{"x":12,"y":48,"width":100,"height":40},
          "sourceLocation":{"fileName":"Main.kt","lineNumber":42},
          "parameters":[{"name":"fontSize","value":{"value":16,"unit":"SP"}}],
          "unmergedSemantics":[{"name":"text","value":"你好"}]}]}}]}
        """#.utf8)
        let snapshot = try SnapshotImporter.decode(data, imageSize: CGSize(width: 1080, height: 2220), packageName: "example")
        let node = snapshot.nodes[1]
        XCTAssertEqual(node.rawID, 9223372036854775806)
        XCTAssertEqual(node.source?.text, "Main.kt:42")
        XCTAssertEqual(node.label, "你好")
        XCTAssertEqual(node.parameters.first?.value, "16sp")
        XCTAssertTrue(node.children.isEmpty)
    }

    func testImporterRejectsUnsupportedRootSchemaAndMultipleDisplays() {
        XCTAssertThrowsError(try SnapshotImporter.decode(Data(#"{"roots":[]}"#.utf8), imageSize: CGSize(width: 100, height: 100), packageName: "example"))
        XCTAssertThrowsError(try SnapshotImporter.decode(Data(#"{"displays":[{"id":0},{"id":1}],"windows":[]}"#.utf8), imageSize: CGSize(width: 100, height: 100), packageName: "example"))
    }

    func testArchiveRoundTripKeepsIssueBindings() throws {
        let snapshot = InspectorSnapshot.demo()
        var ledger = IssueLedger()
        ledger.update(ComponentKey(snapshotID: snapshot.id, nodeID: "email"), description: "修改字号", parameterIDs: ["组件参数.textStyle.fontSize"])
        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(IssueLedger.self, from: data)
        XCTAssertEqual(ledger.issues, restored.issues)
    }
}
