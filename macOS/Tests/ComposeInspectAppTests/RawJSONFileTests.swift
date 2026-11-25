import ComposeInspectCore
import XCTest
@testable import ComposeInspectApp

final class RawJSONFileTests: XCTestCase {
    @MainActor
    func testBoundedPreviewAndFullFileReplacement() async throws {
        let start = "{\"windows\":[{\"text\":\""
        let padding = String(repeating: "a", count: JSONFile.previewLimit - start.utf8.count - 1)
        let bytes = Data((start + padding + "中文" + String(repeating: "b", count: 2_000_000) + "\"}]}").utf8)
        let document = try InspectorDocument(data: bytes)
        let presentation = RawJSONPresentation(title: "测试", document: document, nodePointer: "/windows/0/text")
        let files = JSONFiles()
        let full = try await files.file(for: "完整 JSON", presentation: presentation)
        XCTAssertEqual(full.preview, start + padding)
        XCTAssertEqual(full.size, UInt64(bytes.count))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try full.export(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        for scope in ["节点", "窗口"] {
            let file = try await files.file(for: scope, presentation: presentation)
            try file.export(to: destination)
            let expected = scope == "节点" ? document.root.value(at: "/windows/0/text") : document.windows.first
            XCTAssertEqual(try InspectorJSON.parse(Data(contentsOf: destination)), expected)
        }
    }
}
