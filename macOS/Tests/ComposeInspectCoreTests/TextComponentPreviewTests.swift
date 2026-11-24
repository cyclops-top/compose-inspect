import XCTest
@testable import ComposeInspectCore

final class TextComponentPreviewTests: XCTestCase {
    private func params(_ json: String) throws -> [NodeParameter] {
        try SnapshotImporter.flatten(XCTUnwrap(InspectorJSON.parse(Data(json.utf8)).array), group: .parameter, pointer: "/parameters")
    }
    func testTextResolvesInheritedColorFromMatchingBasicTextAndReportsSPSize() throws {
        let basic = InspectorNode(id: "basic", rawID: 2, name: "BasicText", bounds: .zero,
            parameters: try params(##"[{"name":"text","value":"关于"},{"name":"style","elements":[{"name":"color","value":"#FF293C35"},{"name":"fontSize","value":{"value":14,"unit":"SP"}},{"name":"fontWeight","value":500}]}]"##))
        let text = InspectorNode(id: "text", rawID: 1, name: "Text", bounds: .zero,
            parameters: try params(#"[{"name":"text","value":"关于"},{"name":"color","value":"Unspecified"},{"name":"fontSize","value":"Unspecified"}]"#), children: [basic])
        let preview = try XCTUnwrap(TextComponentPreview(node: text))
        XCTAssertEqual(preview.content, "关于")
        XCTAssertEqual(preview.colorARGB, "FF293C35")
        XCTAssertEqual(preview.fontSize, 14)
        XCTAssertEqual(preview.fontUnit, "sp")
        XCTAssertEqual(preview.fontWeight, 500)
        let explicit = InspectorNode(id: "explicit", rawID: 3, name: "Text", bounds: .zero,
            parameters: try params(##"[{"name":"text","value":"关于"},{"name":"color","value":"#80FF0000"}]"##), children: [basic])
        XCTAssertEqual(TextComponentPreview(node: explicit)?.colorARGB, "80FF0000")
    }
    func testMissingContentStillShowsResolvedWeightAndSkipsOpaqueValues() throws {
        let parameters = try params(#"[{"name":"text","value":"AnnotatedString（未展开）","isTruncated":true},{"name":"fontWeight","value":"FontWeight.Bold"},{"name":"fontSize","value":"Unspecified"}]"#)
        let preview = try XCTUnwrap(TextComponentPreview(node: InspectorNode(id: "t", rawID: 1, name: "Text", bounds: .zero, parameters: parameters)))
        XCTAssertNil(preview.content)
        XCTAssertEqual(preview.fontWeight, 700)
        XCTAssertNil(preview.fontSize)
        XCTAssertNil(preview.colorARGB)
    }

    func testUnrelatedChildTextIsNotBorrowedAndNontextHasNoPreview() throws {
        let child = InspectorNode(id: "child", rawID: 2, name: "BasicText", bounds: .zero,
            parameters: try params(##"[{"name":"text","value":"其他文本"},{"name":"color","value":"#FFFFFFFF"}]"##))
        let text = InspectorNode(id: "text", rawID: 1, name: "Text", bounds: .zero,
            parameters: try params(#"[{"name":"text","value":""}]"#), children: [child])
        XCTAssertEqual(TextComponentPreview(node: text)?.content, "")
        XCTAssertNil(TextComponentPreview(node: text)?.colorARGB)
        XCTAssertNil(TextComponentPreview(node: text)?.fontSize)
        XCTAssertNil(TextComponentPreview(node: InspectorNode(id: "box", rawID: 3, name: "Box", bounds: .zero, children: [child])))
    }
}
