import AppKit
import XCTest
@testable import ComposeInspectApp

final class ScreenshotColorTests: XCTestCase {
    @MainActor func testConsecutiveCopiesReplacePasteboardAndReportLatestColor() {
        let store = WorkspaceStore()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for hex in ["#123456", "#AABBCC", "#AABBCC"] {
            let notice = "已复制 " + hex
            XCTAssertTrue(store.copy(hex, successNotice: notice, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), hex)
            XCTAssertEqual(store.notice, notice)
        }
    }

    @MainActor func testSamplesOriginalRowsAndScalesToBitmapPixels() throws {
        let rows = Data([255, 0, 0, 255, 0, 255, 0, 255,
                         0, 0, 255, 255, 18, 52, 86, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: rows as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bitmap = try XCTUnwrap(ScreenshotPixels(image))
        let size = CGSize(width: 4, height: 4)
        func sample(_ x: CGFloat, _ y: CGFloat) -> String? {
            bitmap.hex(at: CGPoint(x: x, y: y), imageSize: size)
        }
        XCTAssertEqual(sample(0, 0), "#FF0000")
        XCTAssertEqual(sample(2, 1.9), "#00FF00")
        XCTAssertEqual(sample(1.9, 2), "#0000FF")
        XCTAssertEqual(sample(3.9, 3.9), "#123456")
        XCTAssertNil(sample(-0.1, 0))
        XCTAssertNil(sample(4, 3))
        XCTAssertNil(sample(0, 4))

        for magnification in LoupeMagnification.allCases {
            let cursor = bitmap.cursor(for: .zero, magnification: magnification)
            let rendering = try XCTUnwrap(cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let lens = try XCTUnwrap(ScreenshotPixels(rendering))
            let center = cursor.hotSpot
            XCTAssertEqual(lens.hex(at: center, imageSize: cursor.image.size), "#FF0000")
            XCTAssertEqual(lens.hex(at: CGPoint(x: center.x, y: center.y + CGFloat(magnification.rawValue)), imageSize: cursor.image.size), "#0000FF")
        }
    }
}
