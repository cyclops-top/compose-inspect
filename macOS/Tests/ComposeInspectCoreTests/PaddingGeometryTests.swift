import XCTest
@testable import ComposeInspectCore

final class PaddingGeometryTests: XCTestCase {
    func testOnlyPositiveSidesAreFilledWithoutCornerIntersections() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 80)
        let regions = PaddingGeometry.regions(in: rect, insets: .init(left: 10, top: 20, right: 15, bottom: 5))
        XCTAssertEqual(regions, [CGRect(x: 20, y: 20, width: 75, height: 20),
                                CGRect(x: 95, y: 40, width: 15, height: 55),
                                CGRect(x: 20, y: 95, width: 75, height: 5),
                                CGRect(x: 10, y: 40, width: 10, height: 55)])
        for point in [CGPoint(x: 11, y: 21), CGPoint(x: 109, y: 21), CGPoint(x: 11, y: 99), CGPoint(x: 109, y: 99),
                      CGPoint(x: 50, y: 60)] {
            XCTAssertFalse(regions.contains { $0.contains(point) })
        }
        for i in regions.indices {
            for j in regions.indices where i < j { XCTAssertTrue(regions[i].intersection(regions[j]).isEmpty) }
        }
        XCTAssertTrue(PaddingGeometry.regions(in: rect, insets: .init(left: 0, top: 0, right: 0, bottom: 0)).isEmpty)
        XCTAssertEqual(PaddingGeometry.regions(in: rect, insets: .init(left: 0, top: 10, right: 0, bottom: 0)),
                       [CGRect(x: 10, y: 20, width: 100, height: 10)])
    }

    func testNestedHorizontalAndVerticalPaddingLeaveCombinedCornersEmpty() {
        let content = CGRect(x: 64, y: 64, width: 200, height: 48)
        let horizontal = PaddingGeometry.regions(in: CGRect(x: 40, y: 40, width: 248, height: 96),
            insets: .init(left: 24, top: 0, right: 24, bottom: 0), contentBounds: content)
        let vertical = PaddingGeometry.regions(in: CGRect(x: 64, y: 40, width: 200, height: 96),
            insets: .init(left: 0, top: 24, right: 0, bottom: 24), contentBounds: content)
        let regions = horizontal + vertical
        XCTAssertEqual(regions.count, 4)
        for point in [CGPoint(x: 41, y: 41), CGPoint(x: 287, y: 41), CGPoint(x: 41, y: 135), CGPoint(x: 287, y: 135)] {
            XCTAssertFalse(regions.contains { $0.contains(point) })
        }
        for point in [CGPoint(x: 41, y: 80), CGPoint(x: 287, y: 80), CGPoint(x: 100, y: 41), CGPoint(x: 100, y: 135)] {
            XCTAssertEqual(regions.filter { $0.contains(point) }.count, 1)
        }
        XCTAssertTrue(PaddingGeometry.regions(in: .zero, insets: .init(left: 10, top: 10, right: 10, bottom: 10)).isEmpty)
    }
}
