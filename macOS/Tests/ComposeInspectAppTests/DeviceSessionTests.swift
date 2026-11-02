import XCTest
@testable import ComposeInspectApp
@testable import ComposeInspectCore

@MainActor
final class DeviceSessionTests: XCTestCase {
    func testExplicitForegroundRefreshSwitchesRepeatedly() async throws {
        let session = DeviceSession()
        session.selectedSerial = "device"
        session.packageName = "app.first"
        try await session.refreshPackages(selectForeground: true) { _ in
            (["app.first", "app.second"], "app.second")
        }
        XCTAssertEqual(session.packageName, "app.second")
        try await session.refreshPackages(selectForeground: true) { _ in
            (["app.first", "app.second"], "app.first")
        }
        XCTAssertEqual(session.packageName, "app.first")
    }

    func testOrdinaryRefreshPreservesManualOverlaySelectionButInitializesEmptyTarget() async throws {
        let session = DeviceSession()
        session.selectedSerial = "device"
        session.packageName = "app.overlay"
        try await session.refreshPackages { _ in (["app.main", "app.overlay"], "app.main") }
        XCTAssertEqual(session.packageName, "app.overlay")
        session.packageName = ""
        try await session.refreshPackages { _ in (["app.main", "app.overlay"], "app.main") }
        XCTAssertEqual(session.packageName, "app.main")
    }

    func testExplicitRefreshReportsMissingForegroundWithoutClearingSelection() async throws {
        let session = DeviceSession()
        session.selectedSerial = "device"
        session.packageName = "app.selected"
        do {
            try await session.refreshPackages(selectForeground: true) { _ in (["app.selected"], nil) }
            XCTFail("Expected missing foreground error")
        } catch CommandFailure.failed {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(session.packageName, "app.selected")
    }

    func testManualSelectionDuringRefreshWins() async throws {
        let session = DeviceSession()
        session.selectedSerial = "device"
        session.packageName = "app.first"
        try await session.refreshPackages(selectForeground: true) { _ in
            session.packageName = "app.overlay"
            return (["app.main", "app.overlay"], "app.main")
        }
        XCTAssertEqual(session.packageName, "app.overlay")
    }

    func testOlderRefreshCannotOverwriteNewerResult() async throws {
        let session = DeviceSession()
        session.selectedSerial = "device"
        session.packageName = "app.first"
        try await session.refreshPackages(selectForeground: true) { _ in
            try await session.refreshPackages(selectForeground: true) { _ in (["app.new"], "app.new") }
            return (["app.old"], "app.old")
        }
        XCTAssertEqual(session.packageName, "app.new")
        XCTAssertEqual(session.packages, ["app.new"])
    }

    func testDeviceRoundTripInvalidatesPendingRefresh() async throws {
        let session = DeviceSession()
        session.selectedSerial = "A"
        session.packageName = "app.selected"
        try await session.refreshPackages(selectForeground: true) { _ in
            session.selectedSerial = "B"
            session.selectedSerial = "A"
            return (["app.stale"], "app.stale")
        }
        XCTAssertEqual(session.packageName, "app.selected")
        XCTAssertTrue(session.packages.isEmpty)
    }
}
