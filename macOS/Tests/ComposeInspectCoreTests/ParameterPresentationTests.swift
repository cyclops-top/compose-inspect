import XCTest
@testable import ComposeInspectCore

final class ParameterPresentationTests: XCTestCase {
    private func parameters(_ json: String) throws -> [NodeParameter] {
        try SnapshotImporter.flatten(XCTUnwrap(InspectorJSON.parse(Data(json.utf8)).array), group: .parameter, pointer: "/parameters")
    }
    func testEmptyModifierAndEmptyGroupsAreHiddenWithoutLosingRawParametersOrMeaningfulValues() throws {
        let items = try parameters(##"[{"name":"modifier","value":""},{"name":"emptyGroup","elements":[]},{"name":"none","value":null},{"name":"count","value":0},{"name":"enabled","value":false},{"name":"items","isCollection":true,"elements":[]},{"name":"lazy","value":"","isTruncated":true},{"name":"group","elements":[{"name":"child","value":12}]}]"##)
        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(items.filter(\.hasDisplayContent).map(\.name), ["count", "enabled", "items", "lazy", "group", "group.child"])
        XCTAssertEqual(items.first?.original?["value"]?.string, "")
    }
    func testColorPreviewsPreserveARGBAndRejectNoncolors() throws {
        let items = try parameters(##"[{"name":"color","value":"#80ff0000"},{"name":"rgb","value":"#ffffff"},{"name":"transparent","value":"#00000000"},{"name":"number","value":4278190080},{"name":"invalid","value":"#zz000000"},{"name":"notColor","value":"Color.Unspecified"}]"##)
        XCTAssertEqual(items.map(\.colorARGB), ["80FF0000", "FFFFFFFF", "00000000", nil, nil, nil])
        XCTAssertTrue(items[2].hasDisplayContent)
        XCTAssertEqual(items[0].value, "#80ff0000")
    }
    func testFontPresentationGroupsKeepIDsAndOtherNamespacesDistinct() throws {
        let items = try parameters(##"[{"name":"text","value":"关于"},{"name":"color","value":"#FF293C35"},{"name":"fontSize","value":"Unspecified"},{"name":"style","value":"TextStyle","elements":[{"name":"fontSize","value":{"value":14,"unit":"SP"}},{"name":"fontWeight","value":"W400"},{"name":"lineHeight","value":{"value":22,"unit":"SP"}}]},{"name":"modifier","value":""}]"##)
        XCTAssertEqual(items.filter { $0.presentationGroup(isText: true) == .font }.map(\.name),
            ["color", "fontSize", "style", "style.fontSize", "style.fontWeight", "style.lineHeight"])
        XCTAssertEqual(items.first?.presentationGroup(isText: true), .parameter)
        XCTAssertEqual(items.last?.presentationGroup(isText: true), .modifier)
        XCTAssertEqual(items[1].presentationGroup(isText: false), .parameter)
        XCTAssertEqual(items[4].id, "/parameters/3/elements/0")
        XCTAssertEqual(items[4].group, .parameter)
        let semantic = NodeParameter(id: "semantic", name: "fontSize", value: "14sp", group: .semantics)
        XCTAssertEqual(semantic.presentationGroup(isText: true), .semantics)
    }

}
