import XCTest
@testable import ComposeInspectCore

final class ComponentLabelTests: XCTestCase {
    private func snapshot(_ parameters: [[String: Any]]) throws -> InspectorSnapshot {
        let node: [String: Any] = ["type": "ComposeNode", "id": 1, "className": "Button",
            "bounds": ["x": 0, "y": 0, "width": 100, "height": 40],
            "sourceLocation": ["fileName": "Screen.kt", "lineNumber": 12], "mergedSemantics": parameters]
        let data = try JSONSerialization.data(withJSONObject: ["windows": [["root": node]]])
        return try SnapshotImporter.decode(data, imageSize: CGSize(width: 100, height: 100), packageName: "test")
    }
    private func collection(_ elements: [[String: Any]], truncated: Bool = false) -> [String: Any] {
        ["name": "ContentDescription", "value": "List[\(elements.count)]", "isCollection": true,
         "isTruncated": truncated, "elements": elements]
    }
    func testRealCollectionTextReachesTreeAndAILocatorAndRawDataSurvives() throws {
        let snapshot = try snapshot([collection([["name": "[0]", "value": "添加人员"]])])
        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertEqual(node.displayName, "Button「添加人员」")
        let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: node.id), description: "调整", parameterIDs: [])
        let text = try XCTUnwrap(LocatorTextBuilder.text(for: issue, in: snapshot))
        XCTAssertTrue(text.contains("Screen.kt:12 (Button「添加人员」)"))
        XCTAssertFalse(text.contains("List[1]"))
        XCTAssertEqual(node.parameters.first?.value, "List[1]")
    }
    func testMultipleStringsAndLiteralText() throws {
        XCTAssertEqual(try snapshot([collection([["value": "保存", "name": "[0]"], ["value": "草稿", "name": "[1]"]])]).nodes.first?.label, "保存 · 草稿")
        XCTAssertEqual(try snapshot([["name": "Text", "value": "List[1]"]]).nodes.first?.label, "List[1]")
    }
    func testMissingEmptyTruncatedAndNontextValuesHaveNoLabel() throws {
        for parameters in [[], [collection([])], [collection([["name": "[0]", "value": 123]])],
            [collection([["name": "[0]", "value": "保存"]], truncated: true)],
            [["name": "Text", "value": "  \n"]], [["name": "testTag", "value": "submit_button"]]] {
            let snapshot = try snapshot(parameters)
            let node = try XCTUnwrap(snapshot.nodes.first)
            XCTAssertEqual(node.displayName, "Button")
            let issue = ComponentIssue(component: ComponentKey(snapshotID: snapshot.id, nodeID: node.id), description: "调整", parameterIDs: [])
            XCTAssertTrue(try XCTUnwrap(LocatorTextBuilder.text(for: issue, in: snapshot)).contains("Screen.kt:12 (Button)\n"))
        }
    }
    func testUnavailableCollectionFallsBackToRealDescription() throws {
        XCTAssertEqual(try snapshot([collection([]), ["name": "text", "value": "保存"]]).nodes.first?.label, "保存")
    }
}
