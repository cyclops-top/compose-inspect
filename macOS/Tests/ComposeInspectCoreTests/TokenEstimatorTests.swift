import XCTest
@testable import ComposeInspectCore

final class TokenEstimatorTests: XCTestCase {
    func testEmptyAndShortText() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertEqual(TokenEstimator.estimate("a"), 1)
        XCTAssertEqual(TokenEstimator.estimate("hello"), 2)
    }

    func testMixedTextUsesUnicodeScalarsAndRoundsUp() {
        XCTAssertEqual(TokenEstimator.estimate("中文"), 3)
        XCTAssertEqual(TokenEstimator.estimate("中文abcd"), 4)
        XCTAssertEqual(TokenEstimator.estimate("😀"), 2)
        XCTAssertEqual(TokenEstimator.estimate("abcd\n"), 2)
    }
}
