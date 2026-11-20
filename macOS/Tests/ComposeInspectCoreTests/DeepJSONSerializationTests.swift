import XCTest
@testable import ComposeInspectCore

final class DeepJSONSerializationTests: XCTestCase {
    func testConfiguredSDKResponseImportsOnAsyncStack() async throws {
        guard let path = ProcessInfo.processInfo.environment["COMPOSEINSPECT_SDK_RESPONSE"] else {
            throw XCTSkip("Set COMPOSEINSPECT_SDK_RESPONSE to validate a captured SDK response")
        }
        try await Task.detached {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let package = ProcessInfo.processInfo.environment["COMPOSEINSPECT_SDK_PACKAGE"] ?? "cn.bs"
            let started = Date()
            let input: Data
            if path.hasSuffix(".frame") {
                XCTAssertEqual(try SDKCompressedResponse.frameLength(data, maxBytes: 32 * 1024 * 1024), data.count)
                input = try SDKCompressedResponse.decode(Data(data.dropFirst(4)), maxBytes: 32 * 1024 * 1024)
            } else { input = data }
            let snapshot = try SDKSnapshotImporter.decode(input, imageSize: CGSize(width: 1920, height: 1080), packageName: package)
            print("SDK_IMPORT seconds=\(Date().timeIntervalSince(started)) bytes=\(data.count) nodes=\(snapshot.nodes.count)")
            XCTAssertFalse(snapshot.nodes.isEmpty)
        }.value
    }

    func testDeepSerializationOnAsyncTaskStack() async throws {
        try await Task.detached {
            var value: InspectorJSON = .number("9007199254740993")
            for _ in 0..<200 { value = .object(["children": .array([value])]) }
            let expected = String(repeating: "{\"children\":[", count: 200) + "9007199254740993" + String(repeating: "]}", count: 200)
            XCTAssertEqual(value.jsonString(), expected)
            XCTAssertEqual(try InspectorJSON.parse(Data(expected.utf8)).jsonString(), expected)
            XCTAssertEqual(try InspectorJSON.parse(Data(value.jsonString(pretty: true).utf8)).jsonString(), expected)
        }.value
    }

    func testFormattingAndEscaping() throws {
        let value: InspectorJSON = .object(["b": .array([.bool(true), .null]), "a": .string("中文\n\"")])
        let pretty = value.jsonString(pretty: true)
        XCTAssertTrue(pretty.contains("\n  \"b\": [\n    true,\n    null\n  ]"))
        XCTAssertEqual(try InspectorJSON.parse(Data(pretty.utf8)), value)
        XCTAssertEqual(value.jsonString(), try InspectorJSON.parse(Data(pretty.utf8)).jsonString())
    }

    func testStringFastPathStillValidatesUtf8AndJsonEscaping() throws {
        for text in ["plain", "中文 😀", "slash/quote\"backslash\\", "\n\t\r\u{0001}", ""] {
            let encoded = InspectorJSON.string(text).jsonString()
            XCTAssertEqual(try InspectorJSON.parse(Data(encoded.utf8)), .string(text))
        }
        for bytes: [UInt8] in [[34, 0xFF, 34], [34, 0xC0, 0xAF, 34], [34, 1, 34], [34, 92, 120, 34]] {
            XCTAssertThrowsError(try InspectorJSON.parse(Data(bytes)))
        }
        XCTAssertEqual(try InspectorJSON.parse(Data(" \t\r\n{\"x\":9007199254740993}".utf8))["x"], .number("9007199254740993"))
    }
}
