import AppKit
import XCTest
@testable import ComposeInspectApp

final class LocatorMarkdownRendererTests: XCTestCase {
    func testHeadingsAndCodeRenderWithoutMarkdownDelimiters() {
        let rendered = LocatorMarkdownRenderer.render("## 组件路径\n\n```text\nScreen.kt:1 (Screen)\n  → View.kt:2 (Column)\n```\n\n## 修改要求\n**保留文字**")
        XCTAssertTrue(rendered.string.contains("Screen.kt:1 (Screen)\n  → View.kt:2 (Column)"))
        XCTAssertTrue(rendered.string.contains("修改要求"))
        XCTAssertTrue(rendered.string.contains("保留文字"))
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertFalse(rendered.string.contains("##"))
        XCTAssertFalse(rendered.string.contains("**"))
        let headingFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.pointSize, 15)
    }
}
