import XCTest
@testable import ComposeInspectApp

final class ComponentMeasurementTests: XCTestCase {
    private let selected = CGRect(x: 10, y: 20, width: 40, height: 30)

    func testMeasuresEdgesInScreenshotPixelsAndUsesSharedDensity() throws {
        let hovered = CGRect(x: 82, y: 30, width: 20, height: 40)
        let measurement = try XCTUnwrap(ComponentMeasurement(from: selected, to: hovered,
                                                             selectedDensity: 2, hoveredDensity: 2))
        XCTAssertEqual(measurement.lines, [.init(start: CGPoint(x: 50, y: 40), end: CGPoint(x: 82, y: 40), horizontal: true)])
        XCTAssertEqual(measurement.label(for: measurement.lines[0]), "16 dp")

        let fallbackDensities: [Double?] = [nil, 3]
        for density in fallbackDensities {
            let fallback = try XCTUnwrap(ComponentMeasurement(from: selected, to: hovered,
                                                              selectedDensity: 2, hoveredDensity: density))
            XCTAssertEqual(fallback.label(for: fallback.lines[0]), "32 px")
        }
    }

    func testDiagonalSegmentsJoinNearestCornersInBothDirections() throws {
        let other = CGRect(x: 2, y: 4, width: 3, height: 6)
        for (a, b, start, end) in [(selected, other, CGPoint(x: 10, y: 20), CGPoint(x: 5, y: 10)),
                                    (other, selected, CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 20))] {
            let measurement = try XCTUnwrap(ComponentMeasurement(from: a, to: b, selectedDensity: nil, hoveredDensity: nil))
            XCTAssertEqual(measurement.lines.map(\.pixels), [5, 10])
            XCTAssertEqual(measurement.lines.first?.start, start)
            XCTAssertEqual(measurement.lines.first?.end, measurement.lines.last?.start)
            XCTAssertEqual(measurement.lines.last?.end, end)
        }
    }

    func testContainmentUsesOuterFrameInEitherDirection() throws {
        let inner = CGRect(x: 15, y: 20, width: 10, height: 15)
        for (a, b) in [(inner, selected), (selected, inner)] {
            let contained = try XCTUnwrap(ComponentMeasurement(from: a, to: b, selectedDensity: nil, hoveredDensity: nil))
            XCTAssertEqual(contained.lines.map(\.pixels), [5, 25, 0, 15])
            XCTAssertNil(contained.coincidentCenter)
        }
    }

    func testTouchingAndCoincidentFrames() throws {
        let adjacent = CGRect(x: 50, y: 20, width: 20, height: 20)
        let touching = try XCTUnwrap(ComponentMeasurement(from: selected, to: adjacent, selectedDensity: nil, hoveredDensity: nil))
        XCTAssertEqual(touching.lines.map(\.pixels), [0])
        XCTAssertNil(touching.coincidentCenter)

        let coincident = try XCTUnwrap(ComponentMeasurement(from: selected, to: selected, selectedDensity: nil, hoveredDensity: nil))
        XCTAssertTrue(coincident.lines.isEmpty)
        XCTAssertEqual(coincident.coincidentCenter, CGPoint(x: 30, y: 35))
    }

    func testTopOverflowMeasuresLeftRightAndBottomWithinTheOverlap() throws {
        let hovered = CGRect(x: 15, y: 10, width: 20, height: 25)
        let measurement = try XCTUnwrap(ComponentMeasurement(from: selected, to: hovered, selectedDensity: 2, hoveredDensity: 2))
        XCTAssertEqual(measurement.lines, [
            .init(start: CGPoint(x: 10, y: 27.5), end: CGPoint(x: 15, y: 27.5), horizontal: true),
            .init(start: CGPoint(x: 35, y: 27.5), end: CGPoint(x: 50, y: 27.5), horizontal: true),
            .init(start: CGPoint(x: 25, y: 35), end: CGPoint(x: 25, y: 50), horizontal: false),
        ])
        XCTAssertEqual(measurement.lines.map(measurement.label(for:)), ["2.5 dp", "7.5 dp", "7.5 dp"])
    }

    func testCornerOverflowKeepsSelectionAsTheReference() throws {
        let hovered = CGRect(x: 0, y: 10, width: 30, height: 30)
        let measurement = try XCTUnwrap(ComponentMeasurement(from: selected, to: hovered, selectedDensity: nil, hoveredDensity: nil))
        XCTAssertEqual(measurement.lines, [
            .init(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 50, y: 30), horizontal: true),
            .init(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 20, y: 50), horizontal: false),
        ])
        let reversed = try XCTUnwrap(ComponentMeasurement(from: hovered, to: selected, selectedDensity: nil, hoveredDensity: nil))
        XCTAssertEqual(reversed.lines, [
            .init(start: CGPoint(x: 0, y: 30), end: CGPoint(x: 10, y: 30), horizontal: true),
            .init(start: CGPoint(x: 20, y: 10), end: CGPoint(x: 20, y: 20), horizontal: false),
        ])
    }

    func testHorizontalSpanMeasuresOnlyTopAndBottom() throws {
        let hovered = CGRect(x: 0, y: 25, width: 60, height: 15)
        let measurement = try XCTUnwrap(ComponentMeasurement(from: selected, to: hovered, selectedDensity: nil, hoveredDensity: nil))
        XCTAssertEqual(measurement.lines, [
            .init(start: CGPoint(x: 30, y: 20), end: CGPoint(x: 30, y: 25), horizontal: false),
            .init(start: CGPoint(x: 30, y: 40), end: CGPoint(x: 30, y: 50), horizontal: false),
        ])
    }
}
