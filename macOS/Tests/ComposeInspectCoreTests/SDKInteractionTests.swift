import XCTest
@testable import ComposeInspectCore

final class SDKInteractionTests: XCTestCase {
    private func group(_ name: String?, kind: String = "call", click: Bool? = nil,
                       longClick: Bool = false, disabled: Bool = false,
                       children: [InspectorJSON] = [], callback: Bool = false) -> InspectorJSON {
        var raw: [String: InspectorJSON] = [
            "name": name.map(InspectorJSON.string) ?? .null, "kind": .string(kind),
            "boundsInWindow": .array([.number("0"), .number("0"), .number("100"), .number("50")]),
            "children": .array(children), "parameters": .array(callback ? [
                .object(["name": .string("onClick"), "value": .object(["type": .string("Callback"), "opaque": .bool(true)])])
            ] : [])
        ]
        if let click {
            raw["interaction"] = .object(["hasClickAction": .bool(click),
                "hasLongClickAction": .bool(longClick), "disabled": .bool(disabled)])
        }
        return .object(raw)
    }

    private func decode(_ children: [InspectorJSON], sourceOnly: Bool = false) throws -> InspectorSnapshot {
        let raw: InspectorJSON = .object([
            "protocolVersion": .number("1"), "sdkVersion": .string("0.1.3"), "packageName": .string("dev.sample"), "pid": .number("1"),
            "onlySourceNodes": .bool(sourceOnly), "complete": .bool(true), "diagnostics": .array([]), "windows": .array([.object([
                "windowSize": .array([.number("180"), .number("240")]),
                "screenOffset": .array([.number("30"), .number("50")]),
                "tables": .array([.object(["tree": group(nil, children: children)])])
            ])])
        ])
        return try SDKSnapshotImporter.decode(Data(raw.jsonString().utf8),
            imageSize: CGSize(width: 400, height: 600), packageName: "dev.sample")
    }

    func testAnonymousLayoutActionsReachOwningCallsWithoutLeakingAcrossLayoutBoundaries() throws {
        // All rectangles deliberately match: geometry alone must not make the parent/label clickable.
        let label = group("Label", children: [group(nil, kind: "layout", click: false)])
        let inner = group("InnerAction", children: [group(nil, kind: "layout", click: true)])
        let action = group("Action", children: [group(nil, kind: "layout", click: true, children: [label, inner])])
        let root = group("Column", children: [group(nil, kind: "layout", click: false, children: [action])])
        let snapshot = try decode([root])
        XCTAssertEqual(snapshot.nodes.filter(\.isClickable).map(\.name), ["Action", "InnerAction"])
        XCTAssertEqual(InspectorSnapshotIndex(snapshot, onlyClickable: true).nodes.map(\.name), ["Window", "Action", "InnerAction"])
        let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "Action" })
        XCTAssertEqual(node.parameters.first { $0.name == "OnClick" }?.group, .unmergedSemantics)
        XCTAssertEqual(snapshot.document?.root.value(at: node.id)?["unmergedSemantics"]?.array?.first?["value"]?.boolean, true)
    }

    func testMultipleRootsCallbacksDisabledAndLongClickOnlyDoNotBecomeClickable() throws {
        let first = group("First", children: [group(nil, kind: "layout", click: true)])
        let second = group("Second", children: [group(nil, kind: "layout", click: true)])
        let snapshot = try decode([
            group("MultiLayoutWrapper", children: [first, second]),
            group("Disabled", children: [group(nil, kind: "layout", click: true, disabled: true)]),
            group("LongClickOnly", children: [group(nil, kind: "layout", click: false, longClick: true)]),
            group("CallbackOnly", children: [group(nil, kind: "layout", click: false)], callback: true),
            group("OldSDK", children: [group(nil, kind: "layout")], callback: true)
        ])
        XCTAssertEqual(snapshot.nodes.filter(\.isClickable).map(\.name), ["First", "Second"])
        XCTAssertEqual(InspectorSnapshotIndex(snapshot, onlyClickable: true).nodes.map(\.name), ["Window", "First", "Second"])
    }

    func testSourceOnlyPreservesExplicitLayoutOwnershipAndEmptyWindows() throws {
        var raw = try XCTUnwrap(group("Text", click: true).object)
        raw["layoutIdentity"] = .number("42")
        let snapshot = try decode([group("Container", children: [.object(raw)])], sourceOnly: true)
        XCTAssertEqual(snapshot.nodes.filter(\.isClickable).map(\.name), ["Text"])
        XCTAssertEqual(snapshot.nodes.first { $0.name == "Text" }?.clickTargetID, "sdk:42")
        let empty = try decode([], sourceOnly: true)
        let window = try XCTUnwrap(empty.roots.first)
        XCTAssertTrue(window.children.isEmpty)
        XCTAssertEqual(window.bounds, CGRect(x: 30, y: 50, width: 180, height: 240))
    }

    func testCompositionLocalProviderIsHiddenWithoutLosingItsClickableChild() throws {
        let action = group("Action", children: [group(nil, kind: "layout", click: true)])
        let snapshot = try decode([group("CompositionLocalProvider", children: [action])])
        XCTAssertTrue(snapshot.nodes.contains { $0.name == "CompositionLocalProvider" })
        XCTAssertEqual(InspectorSnapshotIndex(snapshot, onlyClickable: true).nodes.map(\.name), ["Window", "Action"])
        XCTAssertEqual(InspectorSnapshotIndex(snapshot, hidingInternals: true).nodes.map(\.name), ["Window", "Action"])
    }

    func testLiveInteractionProbe() throws {
        guard let path = ProcessInfo.processInfo.environment["SDK_INTERACTION_CAPTURE"] else {
            throw XCTSkip("Set SDK_INTERACTION_CAPTURE to the sample interaction capture")
        }
        let snapshot = try SDKSnapshotImporter.decode(Data(contentsOf: URL(fileURLWithPath: path)),
            imageSize: CGSize(width: 1920, height: 1080), packageName: "dev.composeinspect.sample")
        for (label, clickable) in [("click-enabled", true), ("click-disabled", false),
                                    ("click-plain", false), ("click-long-only", false), ("click-custom", true)] {
            let node = try XCTUnwrap(snapshot.nodes.first { $0.name == "BasicText" && $0.label == label })
            XCTAssertEqual(node.isClickable, clickable, label)
        }
        let projected = InspectorSnapshotIndex(snapshot, onlyClickable: true)
        XCTAssertTrue(projected.nodes.contains { $0.label == "click-enabled" })
        XCTAssertTrue(projected.nodes.contains { $0.label == "click-custom" })
        XCTAssertFalse(projected.nodes.contains { ["click-disabled", "click-plain", "click-long-only"].contains($0.label ?? "") })
        XCTAssertFalse(projected.nodes.contains { $0.shortName == "CompositionLocalProvider" })
    }
}
