import XCTest
@testable import ComposeInspectCore

final class SplitLayoutSizingTests: XCTestCase {
    func testRestoresAllSizesAtSameWindowSize() {
        XCTAssertEqual(SplitLayoutSizing.restored(saved: [310, 600, 290], preferred: [240, nil, 300], minimum: [180, 260, 255], available: 1200, flexible: 1), [310, 600, 290])
    }
    func testResizePreservesSidebarsAndBottomHeightUntilMinimumsRequireShrinking() {
        XCTAssertEqual(SplitLayoutSizing.restored(saved: [310, 600, 290], preferred: [240, nil, 300], minimum: [180, 260, 255], available: 1500, flexible: 1), [310, 900, 290])
        XCTAssertEqual(SplitLayoutSizing.restored(saved: [310, 600, 290], preferred: [240, nil, 300], minimum: [180, 260, 255], available: 750, flexible: 1), [200, 260, 290])
        XCTAssertEqual(SplitLayoutSizing.restored(saved: [700, 320], preferred: [nil, 230], minimum: [260, 170], available: 800, flexible: 0), [480, 320])
    }
    func testFirstLaunchAndInvalidSavedValuesUseUsableDefaults() {
        for saved: [Double]? in [nil, [200], [.nan, 300, 400], [-1, 300, 400]] {
            XCTAssertEqual(SplitLayoutSizing.restored(saved: saved, preferred: [240, nil, 300], minimum: [180, 260, 255], available: 1000, flexible: 1), [240, 460, 300])
        }
    }
}
