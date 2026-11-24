import AppKit
import XCTest
@testable import ComposeInspectApp

final class LocatorMarkdownRendererTests: XCTestCase {
    func testMultilineCodeSharesOneBackgroundAcrossEmptyLines() throws {
        let rendered = LocatorMarkdownRenderer.render("~~~swift\nfirst\n\n    second\n~~~\n\n```\nthird\n```\n\n正文 `inline`")
        func range(of substring: String) throws -> NSRange {
            let range = try XCTUnwrap(rendered.string.range(of: substring))
            return NSRange(range, in: rendered.string)
        }
        func block(at offset: Int) -> NSTextBlock? {
            (rendered.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        }
        let code = try range(of: "first\n\n    second")
        let next = try range(of: "third")
        let inline = try range(of: "inline")
        let firstBlock = try XCTUnwrap(block(at: code.location))
        XCTAssertNotNil(firstBlock.backgroundColor)
        for offset in code.location..<NSMaxRange(code) {
            XCTAssertTrue(block(at: offset) === firstBlock)
            XCTAssertNil(rendered.attribute(.backgroundColor, at: offset, effectiveRange: nil))
        }
        let nextBlock = try XCTUnwrap(block(at: next.location))
        XCTAssertFalse(nextBlock === firstBlock)
        XCTAssertNil(block(at: inline.location))
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: inline.location, effectiveRange: nil))
    }

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
