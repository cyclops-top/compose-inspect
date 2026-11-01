import XCTest
@testable import ComposeInspectCore

final class TreeSelectionViewportTests: XCTestCase {
    private let document = CGSize(width: 1000, height: 3000)

    func testVisibleRowKeepsBothScrollPositions() {
        let viewport = CGRect(x: 120, y: 400, width: 300, height: 500)
        let target = CGRect(x: 150, y: 450, width: 140, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: target, in: viewport, documentSize: document), viewport.origin)
    }

    func testOffscreenRowScrollsVerticallyWithoutMovingVisibleLabelHorizontally() {
        let viewport = CGRect(x: 120, y: 400, width: 300, height: 500)
        let below = CGRect(x: 150, y: 1300, width: 140, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: below, in: viewport, documentSize: document), CGPoint(x: 120, y: 828))
        let above = CGRect(x: 150, y: 100, width: 140, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: above, in: viewport, documentSize: document), CGPoint(x: 120, y: 100))
    }

    func testHorizontalRevealUsesMinimumMovementAndLeadingSpace() {
        let viewport = CGRect(x: 120, y: 400, width: 300, height: 500)
        let left = CGRect(x: 80, y: 450, width: 100, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: left, in: viewport, documentSize: document).x, 64)
        let right = CGRect(x: 390, y: 450, width: 100, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: right, in: viewport, documentSize: document).x, 198)
        let long = CGRect(x: 390, y: 450, width: 600, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: long, in: viewport, documentSize: document).x, 374)
        let beginning = CGRect(x: 4, y: 450, width: 100, height: 28)
        XCTAssertEqual(TreeSelectionViewport.origin(revealing: beginning, in: viewport, documentSize: document).x, 0)
    }
}
