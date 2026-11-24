import XCTest
@testable import ComposeInspectCore

final class ComponentObservationTests: XCTestCase {
    private func load(_ name: String) throws -> InspectorSnapshot {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repo.appendingPathComponent("android/validation/observation/\(name).json.gz")
        let recorded = try SDKCompressedResponse.decode(Data(contentsOf: file), maxBytes: 2_000_000)
        // Replay the recorded UI under the current handshake version. Protocol 1 is unchanged.
        var payload = try XCTUnwrap(InspectorJSON.parse(recorded).object)
        payload["sdkVersion"] = .string(SDKInspectorClient.supportedSDKVersion)
        let bytes = InspectorDocument(root: .object(payload)).originalJSON
        let package = "dev.composeinspect.sample"
        let snapshot = try SDKSnapshotImporter.decode(bytes, imageSize: CGSize(width: 1080, height: 2400), packageName: package)
        return snapshot.withCaptureContext(deviceName: "sample", metadata: CaptureMetadata(
            serial: "emulator-5554", packageName: package, startedAt: Date(), finishedAt: Date(), diagnostics: [], baselineJSON: bytes))
    }

    func testCounterAcrossRealCaptures() throws {
        let baseline = try load("baseline"), unchanged = try load("unchanged"), incremented = try load("incremented")
        let node = try XCTUnwrap(baseline.nodes.first { $0.name == "ParameterCard" })
        let fields = node.observableFields
        XCTAssertFalse(fields.contains { $0.name.hasPrefix("profile") || $0.name == "onClick" })
        let count = try XCTUnwrap(fields.first { $0.name == "count" })
        var watch = ComponentObservation(node: node, field: count, snapshot: baseline)
        XCTAssertNotNil(watch.advance(from: baseline, index: .init(baseline), to: unchanged, index: .init(unchanged)), watch.detail)
        XCTAssertTrue(watch.detail.contains("读数相同"))
        XCTAssertNotNil(watch.advance(from: unchanged, index: .init(unchanged), to: incremented, index: .init(incremented)), watch.detail)
        XCTAssertEqual(watch.previous?.value, "7")
        XCTAssertEqual(watch.latest.value, "8")
        XCTAssertFalse(watch.interrupted)
    }

    func testDuplicateCallSitesMissingFieldsAndChangesOfSourceStayUnresolved() throws {
        let base = try load("baseline")
        let current = try XCTUnwrap(base.nodes.first { $0.name == "ParameterCard" })
        let count = try XCTUnwrap(current.observableFields.first { $0.name == "count" })
        func row(_ id: String, _ x: CGFloat = 0, fields: [NodeParameter]? = nil) -> InspectorNode {
            InspectorNode(id: id, rawID: 0, name: current.name, label: "相同",
                          bounds: current.bounds.offsetBy(dx: x, dy: 0), source: current.source,
                          parameters: fields ?? [count])
        }
        func snapshot(_ rows: [InspectorNode], sdk: Bool = true) -> InspectorSnapshot {
            let window = InspectorNode(id: "window", rawID: 0, name: "Window", bounds: .zero, children: rows)
            return InspectorSnapshot(packageName: base.packageName, deviceName: base.deviceName, pixelSize: base.pixelSize,
                                     roots: [window], document: sdk ? base.document : nil, captureMetadata: base.captureMetadata)
        }
        func observe(_ before: InspectorSnapshot, _ after: InspectorSnapshot) -> ComponentObservation {
            let selected = before.roots[0].children[0]
            var watch = ComponentObservation(node: selected, field: count, snapshot: before)
            _ = watch.advance(from: before, index: .init(before), to: after, index: .init(after))
            return watch
        }
        let a = snapshot([row("a")])
        // Whole-screen movement changes geometry and snapshot-local IDs only.
        XCTAssertFalse(observe(a, snapshot([row("b", 120)])).interrupted)
        // Overlapping outgoing/incoming calls during an animation.
        XCTAssertTrue(observe(a, snapshot([row("a"), row("b")])).interrupted)
        // A head insertion cannot turn three identical siblings into a reliable match.
        let twins = snapshot([row("a"), row("b")])
        XCTAssertTrue(observe(twins, snapshot([row("new"), row("a"), row("b")])).interrupted)
        let stopped = observe(a, snapshot([row("b", fields: [])]))
        XCTAssertTrue(stopped.interrupted)
        XCTAssertEqual(stopped.latest.value, "7")
        XCTAssertTrue(observe(a, snapshot([row("a")], sdk: false)).interrupted)
    }

    func testListAndProcessChangesStopObservation() throws {
        let before = try load("baseline"), scrolled = try load("scrolled"), dialog = try load("dialog")
        let row = try XCTUnwrap(before.nodes.first { $0.name == "LazyRowProbe" })
        var watch = ComponentObservation(node: row, field: try XCTUnwrap(row.observableFields.first), snapshot: before)
        XCTAssertNil(watch.advance(from: before, index: .init(before), to: scrolled, index: .init(scrolled)))
        XCTAssertTrue(watch.interrupted)
        XCTAssertEqual(watch.latest.snapshotID, before.id)
        let card = try XCTUnwrap(before.nodes.first { $0.name == "ParameterCard" })
        watch = ComponentObservation(node: card, field: try XCTUnwrap(card.observableFields.first), snapshot: before)
        XCTAssertNil(watch.advance(from: before, index: .init(before), to: dialog, index: .init(dialog)))
        XCTAssertTrue(watch.detail.contains("进程"))
    }

    func testViewportUsesActualStateAndScrollOffsets() throws {
        func viewport(_ file: String, _ component: String) throws -> LazyViewport {
            let snapshot = try load(file)
            let list = try XCTUnwrap(snapshot.nodes.first { $0.name == component })
            return try XCTUnwrap(LazyViewport(node: list))
        }
        let baseline = try viewport("baseline", "LazyColumn")
        XCTAssertEqual(baseline.items.map(\.id), Array(0...4))
        XCTAssertEqual(baseline.items.map(\.extent), Array(repeating: "完整相交", count: 4) + ["部分相交"])
        XCTAssertEqual(baseline.items.first?.key, "0")
        let scrolled = try viewport("scrolled", "LazyColumn")
        XCTAssertGreaterThan(try XCTUnwrap(scrolled.items.first?.id), 0)
        XCTAssertLessThan(try XCTUnwrap(scrolled.items.first?.offset), 0)
        let row = try viewport("interactions", "LazyRow")
        XCTAssertEqual(row.axis, "横向")
        XCTAssertNil(row.items.first?.key)
        let grid = try viewport("interactions", "LazyVerticalGrid")
        XCTAssertNotNil(grid.items.first?.gridBounds)
        XCTAssertEqual(grid.items[0].offset, grid.items[1].offset)
        XCTAssertEqual(grid.items.last?.extent, "部分相交")
    }

    func testMergedAndOwnSemanticsStaySeparate() throws {
        let nodes = try load("interactions").nodes
        let mixed = try XCTUnwrap(nodes.first { $0.name == "BasicText" && $0.label == "mixed" })
        XCTAssertTrue(mixed.observableFields.contains { $0.group == .unmergedSemantics && $0.name == "Selected" && $0.value == "false" })
        XCTAssertTrue(mixed.observableFields.contains { $0.group == .unmergedSemantics && $0.name == "ToggleableState" && $0.value == "Indeterminate" })
        XCTAssertFalse(mixed.observableFields.contains { $0.group == .mergedSemantics })
        XCTAssertTrue(nodes.contains { node in node.observableFields.contains {
            $0.group == .mergedSemantics && $0.name == "ToggleableState" && $0.value == "Indeterminate"
        } })
    }

    func testClickPreflightRejectsOcclusionAndAmbiguousLabels() throws {
        let snapshot = try load("baseline")
        let card = try XCTUnwrap(snapshot.nodes.first { $0.name == "ParameterCard" })
        let target = try ClickTarget(node: card, snapshot: snapshot)
        let package = snapshot.packageName
        let name = "abc " + package + "/.MainActivity"
        let owner = "1: name=\(name), id=2, displayId=0, inputConfig=0x0, frame=[0,0][1080,2400], touchableRegion=[0,0][1080,2400], ownerPid=\(target.pid),"
        let input = """
        Viewport INTERNAL: displayId=0, isActive=[1]

          FocusedWindows:
            displayId=0, name='\(name)'
          FocusRequests:
          Display: 0
            logicalSize=1080x2400
                transform (ROT_0) (IDENTITY)
            Windows:
              0: name=StatusBar, id=1, displayId=0, inputConfig=TRUSTED_OVERLAY, frame=[0,0][1080,74], touchableRegion=[0,0][1080,74],
              \(owner)
        """
        XCTAssertNoThrow(try InspectorClient.checkInputWindows(input, target: target, rotation: 0))
        XCTAssertThrowsError(try InspectorClient.checkInputWindows(input.replacingOccurrences(of: "1080,74", with: "1080,480"), target: target, rotation: 0))
        XCTAssertThrowsError(try InspectorClient.checkInputWindows(input, target: target, rotation: 1))
        XCTAssertThrowsError(try InspectorClient.checkInputWindows(input.replacingOccurrences(of: "ownerPid=\(target.pid)", with: "ownerPid=1"), target: target, rotation: 0))
        let row = #"<node text="\#(target.label)" package="\#(package)" bounds="[95,138][430,181]" clickable="true" enabled="true"/>"#
        func hierarchy(_ content: String) throws -> VerificationHierarchy {
            try VerificationHierarchy(Data(("<hierarchy rotation=\"0\">" + content + "</hierarchy>").utf8))
        }
        XCTAssertNoThrow(try hierarchy(row).check(target))
        XCTAssertThrowsError(try hierarchy(row + row).check(target))
        XCTAssertThrowsError(try hierarchy(row.replacingOccurrences(of: "430,181", with: "96,139")).check(target))
    }

    func testHandshakeRequiresExactVersion() throws {
        var hello: [String: InspectorJSON] = ["protocolVersion": .number("1"), "pid": .number("9"), "packageName": .string("dev.sample")]
        for version in [nil, "0.1.2", "0.1.4"] as [String?] {
            hello["sdkVersion"] = version.map(InspectorJSON.string)
            XCTAssertThrowsError(try SDKInspectorClient.validateResponse(Data(InspectorJSON.object(hello).jsonString().utf8), package: "dev.sample")) {
                XCTAssertTrue($0.localizedDescription.contains("0.1.3"))
            }
        }
    }
}
