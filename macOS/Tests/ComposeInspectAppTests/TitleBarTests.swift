import AppKit
import XCTest
@testable import ComposeInspectApp

final class TitleBarTests: XCTestCase {
    @MainActor
    func testDoubleClickFillsVisibleFrameThenRestoresOriginalFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 120, dy: 100),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "CompScope"
        let delegate = AppDelegate()
        let original = window.frame
        func click(y: CGFloat, count: Int) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: window.frame.width / 2, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
            return delegate.handleTitleBarDoubleClick(event)
        }
        XCTAssertFalse(try click(y: 40, count: 2))
        XCTAssertFalse(try click(y: original.height - 10, count: 1))
        XCTAssertTrue(try click(y: original.height - 10, count: 2))
        XCTAssertEqual(window.frame, screen.visibleFrame)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertTrue(try click(y: window.frame.height - 10, count: 2))
        XCTAssertEqual(window.frame, original)
    }
}
