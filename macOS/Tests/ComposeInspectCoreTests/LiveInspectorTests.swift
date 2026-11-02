import XCTest
@testable import ComposeInspectCore

final class LiveInspectorTests: XCTestCase {
    func testConfiguredDeviceCapturePreservesOriginalDump() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COMPOSEINSPECT_LIVE"] == "1" else { throw XCTSkip("Set COMPOSEINSPECT_LIVE=1 with explicit tool/target paths to run a real-device capture.") }
        func required(_ name: String) throws -> String { try XCTUnwrap(env[name], name) }
        let tools = try InspectorToolchain(adb: URL(fileURLWithPath: required("COMPOSEINSPECT_ADB")),
                                          java: URL(fileURLWithPath: required("COMPOSEINSPECT_JAVA")),
                                          jar: URL(fileURLWithPath: required("COMPOSEINSPECT_JAR")), environment: env)
        let client = InspectorClient(tools: tools)
        let result = try await client.capture(serial: required("COMPOSEINSPECT_SERIAL"),
                                                                    package: required("COMPOSEINSPECT_PACKAGE"), deviceName: "Integration device")
        XCTAssertFalse(result.snapshot.nodes.isEmpty)
        if env["COMPOSEINSPECT_EXPECT_STYLES"] == "1" {
            let styled = result.snapshot.nodes.filter { $0.style != nil }
            XCTAssertFalse(styled.isEmpty, "采集器必须返回实际 Modifier 坐标及样式")
            let padded = try XCTUnwrap(styled.first { node in
                guard let style = node.style else { return false }
                return style.layers.contains { $0.padding != nil } && node.bounds != style.contentBounds
            })
            XCTAssertEqual(padded.bounds, padded.style?.outerBounds)
            let groups = result.snapshot.nodes.filter(\.isVirtualLayoutGroup)
            XCTAssertFalse(groups.isEmpty)
            for group in groups {
                for child in group.children where !child.bounds.isEmpty {
                    XCTAssertTrue(group.bounds.contains(child.bounds), "\(group.name) 必须包含 \(child.name) 的外框")
                }
                XCTAssertNil(group.style)
            }
            XCTAssertTrue(styled.contains { $0.style?.layers.contains { $0.argb != nil } == true })
            XCTAssertTrue(styled.contains { $0.style?.layers.contains { $0.shape?.kind == "rounded" } == true })
        }
        if env["COMPOSEINSPECT_EXPECT_RESIDENT_SHAPES"] == "1" {
            let cards = result.snapshot.nodes.filter { $0.source?.file == "ResidentCard.kt" && $0.source?.line == 44 && $0.name == "Surface" }
            XCTAssertFalse(cards.isEmpty)
            for card in cards {
                let style = try XCTUnwrap(card.style)
                let shape = try XCTUnwrap(style.layers.first { $0.shape?.kind == "rounded" }?.shape)
                for radius in [shape.topLeft, shape.topRight, shape.bottomLeft, shape.bottomRight] {
                    XCTAssertEqual(radius / style.density, 16, accuracy: 0.01)
                }
                XCTAssertEqual(style.totalPadding.left, 0, "Surface must not borrow its parent's item padding")
            }
        }
        if env["COMPOSEINSPECT_EXPECT_PERCENT_SHAPES"] == "1" {
            let fab = try XCTUnwrap(result.snapshot.nodes.first { $0.source?.file == "ResidentListScreen.kt" && $0.name == "FloatingActionButton" && $0.style != nil })
            let style = try XCTUnwrap(fab.style)
            let layer = try XCTUnwrap(style.layers.first { $0.kind == "background" && $0.shape?.kind == "rounded" })
            let shape = try XCTUnwrap(layer.shape)
            XCTAssertEqual(shape.title(in: layer.bounds), "圆形")
            for key in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
                XCTAssertEqual(shape.corners?[key]?.unit, "%")
                XCTAssertEqual(shape.corners?[key]?.value, 50)
            }
            XCTAssertEqual(shape.topLeft, min(layer.bounds.width, layer.bounds.height) / 2, accuracy: 0.01)
            XCTAssertNotEqual(layer.bounds, style.outerBounds, "FAB padding is not its circular shape boundary")
        }
        let document = try XCTUnwrap(result.snapshot.document)
        XCTAssertEqual(try InspectorJSON.parse(document.originalJSON), document.root)
        XCTAssertEqual(result.snapshot.roots.count, document.windows.count)
        XCTAssertNotNil(result.snapshot.captureMetadata)
        let restored = try JSONDecoder().decode(InspectorSnapshot.self, from: JSONEncoder().encode(result.snapshot))
        XCTAssertEqual(restored.document?.originalJSON, document.originalJSON)
        XCTAssertEqual(restored.nodes.count, result.snapshot.nodes.count)
        if let token = result.snapshot.nodes.flatMap(\.parameters).compactMap(\.continuationToken).first {
            let detail = try await client.parameter(serial: required("COMPOSEINSPECT_SERIAL"), package: required("COMPOSEINSPECT_PACKAGE"), token: token)
            XCTAssertEqual(try InspectorJSON.parse(detail.originalJSON), detail.root)
            XCTAssertFalse(detail.originalJSON.isEmpty)
        }
        if let directory = env["COMPOSEINSPECT_LIVE_OUTPUT"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try document.originalJSON.write(to: output.appendingPathComponent("tree.json"))
            try result.imageData.write(to: output.appendingPathComponent("screen.png"))
            try JSONEncoder().encode(result.snapshot.captureMetadata).write(to: output.appendingPathComponent("metadata.json"))
        }
    }
}
